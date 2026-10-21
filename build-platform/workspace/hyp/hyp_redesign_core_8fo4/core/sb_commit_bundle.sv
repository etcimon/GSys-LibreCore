// hyp8 provenance: REWRITTEN (sv-timing emit base, commit bundle stage)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// SPDX-FileCopyrightText: machine-generated
//
// hyp8 (group 6): commit presentation. CommitBundleStages == 1: the
// bundle (commit_instr_o / commit_drop_o / commit_replay_o) is formed from
// the registered head/select plus a SAME-CYCLE match of the writeback
// record trans_id against the presented slot, so a result landing this
// cycle on the head is committable this cycle -- the common-path commit
// timing of the emit's registered-slot presentation is preserved.
// commit_ack_i returns one cycle later (registered inside commit_stage)
// and clears `issued`; the presented slot is held until acked or killed
// because commit_pointer_q only advances on an ack.
//
// commit_bundle_valid_o: per-port "this slot is live AND committable-or-
// droppable this cycle" -- the decision qualifier for the downstream
// commit stage's registered acknowledge (and the RVFI-visible evidence
// that a real candidate was presented).
//
// ld_checked_i: a LOAD-class slot is committable only when the LSQ has
// checked it (memory-order resolution). Tied high until the LSQ group
// lands; the gate sits on the merged valid only -- a cancelled load still
// drops without a check.
//
// H20: the WB merge below must not resurrect a wrong-path result. A
// cancelled slot presents as a drop (commit_drop_o) and the merged
// result/exception is only attached for non-cancelled slots; the same
// combined cancelled_mask that kills the slot gates the PRF write in
// g6lc_prf, so the data cannot architecturally survive either path.

module sb_commit_bundle
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type sb_mem_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type exception_t = logic
) (
    // Live entry array (read-only)
    input  sb_mem_t [G6LCCfg.NR_SB_ENTRIES-1:0]                      mem_q_i,
    // Commit/reclaim pointer (legacy select base)
    input  logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_ptr_i,
    // Combinational per-hart head (MixedSmt select only)
    input  logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0][G6LCCfg.TRANS_ID_BITS-1:0] head_slot_i,
    input  logic [(G6LCCfg.NrHarts < 1 ? 1 : G6LCCfg.NrHarts)-1:0]                          head_valid_i,
    // Writeback records (the registered FU lanes -- rank-2 capture point)
    input  logic [G6LCCfg.NrWbPorts-1:0]                                wt_valid_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0]     trans_id_i,
    input  logic [G6LCCfg.NrWbPorts-1:0][G6LCCfg.XLEN-1:0]              wbdata_i,
    input  exception_t [G6LCCfg.NrWbPorts-1:0]                        ex_i,
    // LSQ load-check (tied high until the LSQ group lands)
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                          ld_checked_i,
    // COH_OOO physical-store ordering inputs
    input  logic [G6LCCfg.NR_SB_ENTRIES-1:0]                          phys_pending_i,
    input  logic                                                      phys_mod_i,
    // Presented mux slot (== commit_ptr_i under legacy)
    output logic [G6LCCfg.NrCommitPorts-1:0][G6LCCfg.TRANS_ID_BITS-1:0] commit_sel_slot_o,
    // Commit presentation - COMMIT_STAGE
    output scoreboard_entry_t [G6LCCfg.NrCommitPorts-1:0]            commit_instr_o,
    output logic              [G6LCCfg.NrCommitPorts-1:0]            commit_drop_o,
    output logic              [G6LCCfg.NrCommitPorts-1:0]            commit_replay_o,
    // hyp8: bundle carries a real committable/droppable candidate
    output logic              [G6LCCfg.NrCommitPorts-1:0]            commit_bundle_valid_o
);
  // svt-stage: begin CB

  localparam int unsigned SB_NH = (G6LCCfg.NrHarts < 1) ? 1 : G6LCCfg.NrHarts;
  localparam int unsigned HID_W = (SB_NH > 1) ? $clog2(SB_NH) : 1;
  localparam bit MixedSmt = (G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff;

  // T6b-4b: flush-capable-privileged class. Anything that can raise a
  // commit-level flush, replay or architectural side effect must be able
  // to reach port 0 -- the only side-effect port. A cancelled entry always
  // carries replay (set at cancel time), so drops are covered too.
  function automatic logic sb_privileged(input sb_mem_t e);
    return e.issued &&
           ((e.sbe.valid && e.sbe.ex.valid) ||
            (e.sbe.fu == g6lc_core_pkg::CSR) ||
            e.replay ||
            (G6LCCfg.RVA && g6lc_core_pkg::is_amo(e.sbe.op)));
  endfunction

  // T6b-4b commit-port slot select.
  //  Port 0: the ring-oldest flush-capable-privileged head when one exists,
  //  else the reclaim entry (the ring-oldest live slot -- today's choice).
  //  Port 1: the legacy +1 slot when it is live, same-hart, and BOTH halves
  //  of the pair are complete (the legacy pair only acks together, so a
  //  live-but-incomplete +1 would park the port behind an unretirable
  //  presentation), else the ring-oldest head of another hart (cross-hart),
  //  else +1 again so a dead presentation traces identically to the legacy
  //  slot.
  //  Under !MixedSmt the select is commit_ptr_i -- bit-identical.
  localparam int unsigned NWBP = G6LCCfg.NrWbPorts;
  localparam int unsigned WLV = (NWBP > 1) ? $clog2(NWBP) : 1;

  function automatic logic [NWBP-1:0] wb_hi(input logic [NWBP-1:0] x);
    logic [NWBP-1:0] a;
    a = x >> 1;
    for (int unsigned l = 1; l < NWBP; l = l << 1) a = a | (a >> l);
    return x & ~a;
  endfunction

  // hyp8: balanced min-tree levels over SB_NH heads + per-bit vector
  // extract for the one-hot masked-OR slot select.
  localparam int unsigned SLV2 = (SB_NH > 1) ? $clog2(SB_NH) : 1;
  function automatic logic [SB_NH-1:0] sb_bits(
      input logic [SB_NH-1:0][G6LCCfg.TRANS_ID_BITS-1:0] v,
      input int unsigned b);
    for (int unsigned h = 0; h < SB_NH; h++) sb_bits[h] = v[h][b];
  endfunction

  // hyp8 r3: one-hot select ring for the masked-OR gathers; idx_col is a
  // constant transpose of the slot index used by the boundary encoders.
  localparam int unsigned NSE = G6LCCfg.NR_SB_ENTRIES;
  logic [G6LCCfg.NrCommitPorts-1:0][NSE-1:0]             sel_oh;
  logic [G6LCCfg.TRANS_ID_BITS-1:0][NSE-1:0]             idx_col;
  for (genvar s = 0; s < NSE; s++) begin : gen_idxcol
    for (genvar b = 0; b < G6LCCfg.TRANS_ID_BITS; b++) begin : gen_icb
      assign idx_col[b][s] = (s >> b) & 1;
    end
  end
  function automatic logic [SB_NH-1:0] sb_hbits(
      input logic [SB_NH-1:0][NSE-1:0] v,
      input int unsigned s);
    for (int unsigned h = 0; h < SB_NH; h++) sb_hbits[h] = v[h][s];
  endfunction

  // hyp8: inline the condition so const-eval prunes the whole MixedSmt
  // select under NrHarts==1 (MixedSmt kept for documentation).
  if ((G6LCCfg.NrHarts > 1) && !G6LCCfg.SmtDrainedHandoff) begin : gen_mixed_commit_sel
    // hyp8 r3: one-hot carried selects. The r2 form serialized six
    // encoded-index NR:1 reads (sl_*[head_slot_i] per hart, the slot
    // re-encode, sl_*[port0_sel], mem_q_i[slot]). Carry the select as a
    // one-hot ring vector instead: head_oh decodes head_slot_i once per
    // hart, every table read is a masked-OR gather, the +1 ring
    // successor is a one-hot rotate, and the encoded output slot is
    // produced once at the boundary by a constant-bit gather.
    logic [SB_NH-1:0]                            priv, p0_oh, x_ok, x_oh;
    logic [SB_NH-1:0][G6LCCfg.TRANS_ID_BITS-1:0] hdist;
    logic [SB_NH-1:0][G6LCCfg.TRANS_ID_BITS-1:0] mint [SLV2+1];
    logic [SB_NH-1:0][G6LCCfg.TRANS_ID_BITS-1:0] xmt  [SLV2+1];
    logic [SB_NH-1:0][NSE-1:0]                   head_oh;
    logic [NSE-1:0]   cptr_oh, p0_sel_oh, p1_leg_oh, p1_sel_oh;
    logic [NSE-1:0]   p0_slot_oh, x_slot_oh;
    logic [G6LCCfg.TRANS_ID_BITS-1:0] p0_min, x_min;
    logic [HID_W-1:0]                 port0_hart, p1_leg_hart;
    logic                            p1_leg_ok, p1_x_ok;

    // hyp8: per-slot narrow vectors at static indices -- selecting the
    // whole sb_mem_t record through a NR:1 mux per head serialized the
    // wide record read in front of every compare. Only the fields the
    // select logic needs cross the masked-OR gather.
    logic [G6LCCfg.NR_SB_ENTRIES-1:0]             sl_priv, sl_done,
                                                sl_issued, sl_valid,
                                                sl_cancel;
    logic [G6LCCfg.NR_SB_ENTRIES-1:0][HID_W-1:0]  sl_hart;
    for (genvar s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin : gen_slvec
      assign sl_issued[s] = mem_q_i[s].issued;
      assign sl_valid[s]  = mem_q_i[s].sbe.valid;
      assign sl_cancel[s] = mem_q_i[s].cancelled;
      assign sl_done[s]   = mem_q_i[s].sbe.valid ||
                            mem_q_i[s].cancelled || mem_q_i[s].replay;
      assign sl_priv[s]   = sb_privileged(mem_q_i[s]);
      assign sl_hart[s]   = mem_q_i[s].sbe.hart_id;
    end

    // slot ring: encoded index -> one-hot, decoded once per producer
    for (genvar h = 0; h < SB_NH; h++) begin : gen_hoh
      assign head_oh[h] = NSE'(1) << head_slot_i[h];
    end
    assign cptr_oh = NSE'(1) << commit_ptr_i[0];

    // Port 0 candidate filter + balanced min tree over ring distance.
    // Ties on hdist cannot occur (head_slot_i entries are distinct), so
    // equality to the tree minimum is already a one-hot.
    for (genvar h = 0; h < SB_NH; h++) begin : gen_hcand
      // The override may only reroute a privileged head that can commit
      // now (wb'd, dropped, or replay-marked -- the drop path acks
      // without sbe.valid). An un-issuable privileged head must NOT take
      // port 0: it would park the port behind the reclaim entry whose
      // own commit is exactly what that head waits on. A non-committable
      // head gets port 0 anyway once the reclaim pointer reaches it.
      assign priv[h]  = head_valid_i[h] && |(head_oh[h] & sl_priv) &&
                        |(head_oh[h] & sl_done);
      assign hdist[h] = head_slot_i[h] - commit_ptr_i[0];
      assign mint[0][h] = priv[h] ? hdist[h] : '1;
    end
    for (genvar l = 0; l < SLV2; l++) begin : gen_mlvl
      localparam int unsigned NW = (SB_NH + (1 << l) - 1) >> l;
      localparam int unsigned NX = (SB_NH + (1 << (l + 1)) - 1) >> (l + 1);
      for (genvar t = 0; t < SB_NH; t++) begin : gen_mt
        if (t < NX) begin : gen_in
          if (2 * t + 1 < NW) begin : gen_pair
            assign mint[l+1][t] = (mint[l][2*t] < mint[l][2*t+1])
                                  ? mint[l][2*t] : mint[l][2*t+1];
          end else begin : gen_odd
            assign mint[l+1][t] = mint[l][2*t];
          end
        end else begin : gen_pad
          assign mint[l+1][t] = '1;
        end
      end
    end
    assign p0_min = mint[SLV2][0];
    for (genvar h = 0; h < SB_NH; h++) begin : gen_p0oh
      assign p0_oh[h] = priv[h] && (hdist[h] == p0_min);
    end
    // the chosen head's slot as one-hot: masked-OR of head_oh columns
    for (genvar s = 0; s < NSE; s++) begin : gen_p0s
      assign p0_slot_oh[s] = |(p0_oh & sb_hbits(head_oh, s));
    end
    // port 0 -- ring-oldest committable privileged head, else the reclaim
    // entry.
    assign p0_sel_oh = (|p0_oh) ? p0_slot_oh : cptr_oh;
    for (genvar b = 0; b < HID_W; b++) begin : gen_p0h
      assign port0_hart[b] = |(p0_sel_oh & sb_bits(sl_hart, b));
    end
    // port 1 -- legacy +1 slot = one-hot ring rotate, then the other
    // hart's head.
    assign p1_leg_oh = {p0_sel_oh[NSE-2:0], p0_sel_oh[NSE-1]};
    for (genvar b = 0; b < HID_W; b++) begin : gen_p1h
      assign p1_leg_hart[b] = |(p1_leg_oh & sb_bits(sl_hart, b));
    end
    assign p1_leg_ok = |(p1_leg_oh & sl_issued) &&
                       (p1_leg_hart == port0_hart) &&
                       (|(p0_sel_oh & sl_valid) ||
                        |(p0_sel_oh & sl_cancel)) &&
                       (|(p1_leg_oh & sl_valid) ||
                        |(p1_leg_oh & sl_cancel));
    for (genvar h = 0; h < SB_NH; h++) begin : gen_xcand
      assign x_ok[h]   = (HID_W'(h) != port0_hart) && head_valid_i[h] &&
                         !(|(head_oh[h] & p0_sel_oh));
      assign xmt[0][h] = x_ok[h] ? hdist[h] : '1;
    end
    for (genvar l = 0; l < SLV2; l++) begin : gen_xlvl
      localparam int unsigned NW = (SB_NH + (1 << l) - 1) >> l;
      localparam int unsigned NX = (SB_NH + (1 << (l + 1)) - 1) >> (l + 1);
      for (genvar t = 0; t < SB_NH; t++) begin : gen_xt
        if (t < NX) begin : gen_in
          if (2 * t + 1 < NW) begin : gen_pair
            assign xmt[l+1][t] = (xmt[l][2*t] < xmt[l][2*t+1])
                                 ? xmt[l][2*t] : xmt[l][2*t+1];
          end else begin : gen_odd
            assign xmt[l+1][t] = xmt[l][2*t];
          end
        end else begin : gen_pad
          assign xmt[l+1][t] = '1;
        end
      end
    end
    assign x_min = xmt[SLV2][0];
    for (genvar h = 0; h < SB_NH; h++) begin : gen_xoh
      assign x_oh[h] = x_ok[h] && (hdist[h] == x_min);
    end
    for (genvar s = 0; s < NSE; s++) begin : gen_xs
      assign x_slot_oh[s] = |(x_oh & sb_hbits(head_oh, s));
    end
    assign p1_x_ok = |x_oh;
    assign p1_sel_oh = (p1_leg_ok || !p1_x_ok) ? p1_leg_oh : x_slot_oh;

    // boundary: per-port select one-hot + the encoded slot produced once
    // by a constant-bit gather.
    assign sel_oh[0] = p0_sel_oh;
    if (G6LCCfg.NrCommitPorts > 1) begin : gen_soh1
      assign sel_oh[1] = p1_sel_oh;
    end
    for (genvar k = 2; k < G6LCCfg.NrCommitPorts; k++) begin : gen_sohk
      assign sel_oh[k] = {p0_sel_oh[NSE-1-k:0],
                          p0_sel_oh[NSE-1:NSE-k]};
    end
    for (genvar k = 0; k < G6LCCfg.NrCommitPorts; k++) begin : gen_enc
      for (genvar b = 0; b < G6LCCfg.TRANS_ID_BITS; b++) begin : gen_eb
        assign commit_sel_slot_o[k][b] = |(sel_oh[k] & idx_col[b]);
      end
    end
  end else begin : gen_legacy_commit_sel
    for (genvar k = 0; k < G6LCCfg.NrCommitPorts; k++) begin : gen_leg
      assign sel_oh[k]               = NSE'(1) << commit_ptr_i[k];
      assign commit_sel_slot_o[k]    = commit_ptr_i[k];
    end
  end

  // output commit instruction directly, with the same-cycle WB merge
  // hyp8: per-port write to independent LHS nets.
  // hyp8 r3: bit-transposed record columns so the per-port read is a
  // masked-OR gather on sel_oh.
  logic [G6LCCfg.NR_SB_ENTRIES-1:0][$bits(sb_mem_t)-1:0] mem_flat;
  logic [$bits(sb_mem_t)-1:0][G6LCCfg.NR_SB_ENTRIES-1:0] mem_col;
  for (genvar s = 0; s < G6LCCfg.NR_SB_ENTRIES; s++) begin : gen_mflat
    assign mem_flat[s] = mem_q_i[s];
    for (genvar b = 0; b < $bits(sb_mem_t); b++) begin : gen_mcol
      assign mem_col[b][s] = mem_flat[s][b];
    end
  end

  // hyp8: per-port write to independent LHS nets. The same-cycle WB match
  // is a per-port compare vector resolved by a downward-prefix one-hot
  // (the emit's serial w-loop keeps the LAST matching writer) and a
  // masked-OR pairwise gather of wbdata/ex.

  for (genvar i = 0; i < G6LCCfg.NrCommitPorts; i++) begin : gen_cport
    logic [G6LCCfg.TRANS_ID_BITS-1:0] slot;
    logic [NWBP-1:0] wh, whi;
    logic [G6LCCfg.XLEN-1:0] wbres;
    exception_t wbex;
    logic wb_hit, ld_ok, merged_valid;

    assign slot = commit_sel_slot_o[i];
    for (genvar w = 0; w < NWBP; w++) begin : gen_wh
      assign wh[w] = wt_valid_i[w] && (trans_id_i[w] == slot);
    end
    assign whi = wb_hi(wh);
    // masked-OR pairwise trees over wb lanes (one-hot or zero)
    logic [WLV:0][NWBP-1:0][G6LCCfg.XLEN-1:0] rt;
    logic [WLV:0][NWBP-1:0][$bits(exception_t)-1:0] et;
    for (genvar w = 0; w < NWBP; w++) begin : gen_wt0
      assign rt[0][w] = {G6LCCfg.XLEN{whi[w]}} & wbdata_i[w];
      assign et[0][w] = {$bits(exception_t){whi[w]}} & $bits(exception_t)'(ex_i[w]);
    end
    for (genvar l = 0; l < WLV; l++) begin : gen_lvl
      for (genvar t = 0; t < NWBP; t++) begin : gen_or
        if (t < ((NWBP + (1 << l) - 1) >> (l + 1))) begin : gen_cmp
          if ((2 * t + 1) < ((NWBP + (1 << l) - 1) >> l)) begin : gen_pair
            assign rt[l+1][t] = rt[l][2*t] | rt[l][2*t+1];
            assign et[l+1][t] = et[l][2*t] | et[l][2*t+1];
          end else begin : gen_odd
            assign rt[l+1][t] = rt[l][2*t];
            assign et[l+1][t] = et[l][2*t];
          end
        end else begin : gen_pad
          assign rt[l+1][t] = '0;
          assign et[l+1][t] = '0;
        end
      end
    end
    assign wbres = rt[WLV][0];
    assign wbex  = exception_t'(et[WLV][0]);
    // hyp8 r3: the record read is a masked-OR gather off the select
    // one-hot, not an encoded-index NR:1 record mux.
    sb_mem_t sel_mem;
    scoreboard_entry_t sel_sbe;
    logic [$bits(sb_mem_t)-1:0] sel_flat;
    for (genvar b = 0; b < $bits(sb_mem_t); b++) begin : gen_smem
      assign sel_flat[b] = |(sel_oh[i] & mem_col[b]);
    end
    assign sel_mem = sb_mem_t'(sel_flat);
    assign sel_sbe = sel_mem.sbe;

    // A dropped (cancelled) slot never merges a wrong-path result: its
    // presentation is the drop, not the data.
    assign wb_hit = (|wh) && !sel_mem.cancelled;
    // hyp8: load-check gate -- a LOAD slot is committable only after the
    // LSQ reports its memory-order check. Drops bypass the gate.
    assign ld_ok = (sel_sbe.fu != g6lc_core_pkg::LOAD) ||
                   |(sel_oh[i] & ld_checked_i);

    // hyp8: per-field assigns instead of the rec-copy + patch sequence so
    // each output field bills as an independent LHS (the wide struct move
    // serialized the whole 30-field record as one chain).
    exception_t ex_merged;
    always_comb begin : cport_ex
      ex_merged = sel_sbe.ex;
      if (wb_hit && wbex.valid) ex_merged = wbex;
      else if (wb_hit && G6LCCfg.FpPresent &&
               (sel_sbe.fu == g6lc_core_pkg::FPU ||
                sel_sbe.fu == g6lc_core_pkg::FPU_VEC))
        ex_merged.cause = wbex.cause;
    end
    logic rec_valid;
    always_comb begin : cport_valid
      rec_valid = (sel_sbe.valid | wb_hit) && ld_ok;
      if (G6LCCfg.CohPolicy == config_pkg::COH_OOO &&
          !sel_mem.cancelled && !ex_merged.valid &&
          (|(sel_oh[i] & phys_pending_i) ||
           (phys_mod_i && sel_sbe.fu == g6lc_core_pkg::LOAD)))
        rec_valid = 1'b0;
    end
    assign commit_instr_o[i].pc          = sel_sbe.pc;
    assign commit_instr_o[i].trans_id    = slot;
    assign commit_instr_o[i].fu          = sel_sbe.fu;
    assign commit_instr_o[i].op          = sel_sbe.op;
    assign commit_instr_o[i].rs1         = sel_sbe.rs1;
    assign commit_instr_o[i].rs2         = sel_sbe.rs2;
    assign commit_instr_o[i].rd          = sel_sbe.rd;
    assign commit_instr_o[i].result      = wb_hit ? wbres : sel_sbe.result;
    assign commit_instr_o[i].valid       = rec_valid;
    assign commit_instr_o[i].use_imm     = sel_sbe.use_imm;
    assign commit_instr_o[i].use_zimm    = sel_sbe.use_zimm;
    assign commit_instr_o[i].use_pc      = sel_sbe.use_pc;
    assign commit_instr_o[i].ex          = ex_merged;
    assign commit_instr_o[i].bp          = sel_sbe.bp;
    assign commit_instr_o[i].is_compressed = sel_sbe.is_compressed;
    assign commit_instr_o[i].is_macro_instr = sel_sbe.is_macro_instr;
    assign commit_instr_o[i].is_last_macro_instr =
        sel_sbe.is_last_macro_instr;
    assign commit_instr_o[i].is_double_rd_macro_instr =
        sel_sbe.is_double_rd_macro_instr;
    assign commit_instr_o[i].vfp         = sel_sbe.vfp;
    assign commit_instr_o[i].is_zcmt     = sel_sbe.is_zcmt;
    assign commit_instr_o[i].hart_id     = sel_sbe.hart_id;
    assign commit_instr_o[i].p_rs1       = sel_sbe.p_rs1;
    assign commit_instr_o[i].p_rs2       = sel_sbe.p_rs2;
    assign commit_instr_o[i].p_rd        = sel_sbe.p_rd;
    assign commit_instr_o[i].p_frs1      = sel_sbe.p_frs1;
    assign commit_instr_o[i].p_frs2      = sel_sbe.p_frs2;
    assign commit_instr_o[i].p_frs3      = sel_sbe.p_frs3;
    assign commit_instr_o[i].p_frd       = sel_sbe.p_frd;
    assign commit_instr_o[i].ooo_renamed = sel_sbe.ooo_renamed;
    assign commit_drop_o[i]   = sel_mem.cancelled;
    assign commit_replay_o[i] = sel_mem.replay;
    // Bundle validity: the slot is live and decidable this cycle.
    assign commit_bundle_valid_o[i] = sel_mem.issued &&
                                      (rec_valid || commit_drop_o[i]);
    assign merged_valid = rec_valid;
  end

  // svt-stage: end CB
  // svt-stage: class CB decision
endmodule
