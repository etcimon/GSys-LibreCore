// hyp8 provenance: REWRITTEN (rename state core + recovery)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_rename_recover -- the state core of the staged rename
// (analysis/g6lc_rename.md). Owns every persistent structure the unbanked
// g6lc_rename kept in one always_comb: speculative/architectural maps for
// both register classes, free/busy vectors, register ownership, the
// per-hart checkpoint rings, and their payload arrays.
//
// One always_comb computes next state, applying events in the unbanked
// order:
//   publish (map/busy/owner writes, checkpoint payloads + alloc marks)
//   -> reserve (new group's picks out of the free lists, ckpt count)
//   -> writeback busy clears
//   -> commit frees (with the free_rep repair basis)
//   -> killed-group pick/ckpt return (exactly once)
//   -> registered mispredict repair (select registered at t, applied t+1;
//     recovering_o holds dispatch out of the pipe both cycles)
//   -> checkpoint retire -> architectural-map commit updates
//   -> per-hart flush -> full flush.
//
// The A147 invariant of the unbanked design -- no allocation during a
// recovery cycle -- is preserved by construction: reserve/publish are
// pipe events and the wrapper holds the pipe empty while recovering_o is
// asserted. The repair itself is the unbanked squash: the squashed set is
// exactly the checkpoint's alloc-mask minus what is already free; map is
// restored, free/busy repaired (never reinstated -- commit frees and WB
// clears that landed after the checkpoint survive).

module g6lc_rename_recover #(
    parameter int unsigned PRF_ENTRIES  = 72,
    parameter int unsigned PRF_W        = 7,
    parameter int unsigned NR_PORTS     = 2,
    parameter int unsigned NR_FREE      = 2,
    parameter int unsigned NR_WB        = 1,
    parameter int unsigned NR_HARTS     = 1,
    parameter int unsigned CKPT_DEPTH   = 8,
    parameter int unsigned FPRF_ENTRIES = 0,
    parameter int unsigned FPRF_W       = 1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0] flush_hart_i,
    input  logic mispredict_i,
    input  logic [$clog2(CKPT_DEPTH+1)-1:0] mispredict_level_i,
    // R1 reservation (asserted on the capture edge).
    input  logic res_v_i,
    input  logic [PRF_ENTRIES-1:0]    res_pick_mask_i,
    input  logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] res_fpick_mask_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][$clog2(CKPT_DEPTH+1)-1:0] res_br_inc_i,
    // R3 publish (asserted the cycle the group retires from the pipe).
    input  logic pub_v_i,
    input  logic [NR_PORTS-1:0]       pub_map_wr_v_i,
    input  logic [NR_PORTS-1:0][1:0]  pub_map_h_i,
    input  logic [NR_PORTS-1:0][4:0]  pub_map_rd_i,
    input  logic [NR_PORTS-1:0][7:0]  pub_map_prd_i,
    input  logic [NR_PORTS-1:0]       pub_fmap_wr_v_i,
    input  logic [NR_PORTS-1:0][7:0]  pub_fmap_prd_i,
    input  logic [PRF_ENTRIES-1:0]    pub_busy_set_i,
    input  logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] pub_fbusy_set_i,
    input  logic [NR_PORTS-1:0]       pub_own_v_i,
    input  logic [NR_PORTS-1:0][7:0]  pub_own_idx_i,
    input  logic [NR_PORTS-1:0][1:0]  pub_own_h_i,
    input  logic [NR_PORTS-1:0]       pub_fown_v_i,
    input  logic [NR_PORTS-1:0][7:0]  pub_fown_idx_i,
    input  logic [NR_PORTS-1:0]       pub_ck_v_i,
    input  logic [NR_PORTS-1:0][5:0]  pub_ck_slot_i,
    input  logic [NR_PORTS-1:0][1:0]  pub_ck_h_i,
    input  logic [NR_PORTS-1:0][31:0][PRF_W-1:0]  pub_ck_map_i,
    input  logic [NR_PORTS-1:0][31:0][FPRF_W-1:0] pub_ck_fmap_i,
    input  logic [NR_PORTS-1:0][PRF_ENTRIES-1:0] pub_ck_aval_i,
    input  logic [NR_PORTS-1:0][(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] pub_ck_faval_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][PRF_ENTRIES-1:0] pub_mark_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] pub_fmark_i,
    // Killed in-flight group: pick masks return exactly once. Checkpoint
    // reservations need no un-count -- a killed lane's slot drops with the
    // ring unwind (mispredict) or the per-hart ring reset (flush_hart),
    // and a surviving partial group never loses a mid-ring slot.
    input  logic kill_v_i,
    input  logic [PRF_ENTRIES-1:0]    kill_pick_mask_i,
    input  logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] kill_fpick_mask_i,
    // Writeback busy clears.
    input  logic [NR_WB-1:0]          wb_valid_i,
    input  logic [NR_WB-1:0][PRF_W-1:0] wb_prd_i,
    input  logic [NR_WB-1:0]          fwb_valid_i,
    input  logic [NR_WB-1:0][FPRF_W-1:0] fwb_prd_i,
    // Commit frees (predecessor physicals, both classes).
    input  logic [NR_FREE-1:0]        free_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] free_prd_i,
    input  logic [NR_FREE-1:0]        ffree_i,
    input  logic [NR_FREE-1:0][FPRF_W-1:0] ffree_prd_i,
    // Checkpoint retire + architectural-map commit updates.
    input  logic [NR_FREE-1:0]        ckpt_retire_i,
    input  logic [NR_FREE-1:0]        commit_valid_i,
    input  logic [NR_FREE-1:0][(NR_HARTS<=1?1:$clog2(NR_HARTS))-1:0] commit_hart_i,
    input  logic [NR_FREE-1:0][4:0]   commit_rd_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] commit_prd_i,
    input  logic [NR_FREE-1:0]        commit_is_fpr_i,
    input  logic [NR_FREE-1:0][FPRF_W-1:0] commit_fprd_i,
    // Registered state out to g6lc_rename_read.
    output logic [(NR_HARTS<1?1:NR_HARTS)-1:0][31:0][PRF_W-1:0]  map_q_o,
    output logic [(NR_HARTS<1?1:NR_HARTS)-1:0][31:0][FPRF_W-1:0] fmap_q_o,
    output logic [PRF_ENTRIES-1:0]    free_q_o,
    output logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] ffree_q_o,
    output logic [PRF_ENTRIES-1:0]    busy_q_o,
    output logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] fbusy_q_o,
    output logic [(NR_HARTS<1?1:NR_HARTS)-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_cnt_q_o,
    output logic [(NR_HARTS<1?1:NR_HARTS)-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_head_q_o,
    // A recovery cycle is in progress (mispredict select or its repair);
    // the wrapper must not admit or publish a group.
    output logic                      recovering_o
);

  localparam int unsigned NH    = (NR_HARTS < 1) ? 1 : NR_HARTS;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);
  localparam int unsigned FPN   = (FPRF_ENTRIES < 1) ? 1 : FPRF_ENTRIES;
  localparam bit          FP_EN = (FPRF_ENTRIES >= 32);
  localparam int unsigned LVL_W = $clog2(CKPT_DEPTH+1);
  localparam int unsigned CKPT_PER_HART = (CKPT_DEPTH / NH < 1) ? 1 : CKPT_DEPTH / NH;

  function automatic logic [LVL_W-1:0] ckpt_slot(input int unsigned h,
                                               input int unsigned v);
    int unsigned t;
    t = v;
    for (int unsigned i = 0; i < 3; i++) if (t >= CKPT_PER_HART) t -= CKPT_PER_HART;
    return LVL_W'(h * CKPT_PER_HART + t);
  endfunction

  logic [NH-1:0][31:0][PRF_W-1:0] map_q, map_d;
  logic [NH-1:0][31:0][PRF_W-1:0] amap_q, amap_d;
  logic [PRF_ENTRIES-1:0] free_q, free_d;
  logic [PRF_ENTRIES-1:0] busy_q, busy_d;
  logic [NH-1:0][31:0][FPRF_W-1:0] fmap_q, fmap_d;
  logic [NH-1:0][31:0][FPRF_W-1:0] famap_q, famap_d;
  logic [FPN-1:0] ffree_q, ffree_d;
  logic [FPN-1:0] fbusy_q, fbusy_d;
  logic [PRF_ENTRIES-1:0][HID_W-1:0] owner_q, owner_d;
  logic [FPN-1:0][HID_W-1:0] fowner_q, fowner_d;
  logic [CKPT_DEPTH-1:0][31:0][FPRF_W-1:0] ckpt_fmap_q;
  logic [CKPT_DEPTH-1:0][FPN-1:0] ckpt_falloc_q, ckpt_falloc_d;
  logic [CKPT_DEPTH-1:0][31:0][PRF_W-1:0] ckpt_map_q;
  logic [CKPT_DEPTH-1:0][HID_W-1:0] ckpt_hart_q, ckpt_hart_d;
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0] ckpt_alloc_q, ckpt_alloc_d;
  logic [NH-1:0][LVL_W-1:0] ckpt_head_q, ckpt_head_d;
  logic [NH-1:0][LVL_W-1:0] ckpt_cnt_q, ckpt_cnt_d;

  // hyp8 r5: per-slot registered ring index. pos_q[s] is the slot's
  // position inside its hart's ring window -- (s - base - head) mod
  // CKPT_PER_HART -- i.e. exactly the quantity the original restore
  // recomputed with a subtract+wrap at mispredict/repair time. It is
  // maintained next-state from head_d (parallel per slot, a 4-bit
  // subtract + conditional add), so slot positions are always distinct
  // inside a slice and pos < cnt identifies the live window. The select
  // and the t+1 repair both read it via one-hot gathers; the wrap/clamp
  // arithmetic is off both paths.
  logic [CKPT_DEPTH-1:0][LVL_W-1:0] pos_q, pos_d;

  // Registered recovery select (mispredict at t, repair at t+1). The
  // unwind slot is held one-hot (rec_oh_q) so the repair gathers the
  // checkpoint payload columns by masked-OR instead of dynamic-index
  // reads; the slot's ring position is re-gathered at repair time so a
  // checkpoint retire that landed in between cannot skew it (pos_q
  // already tracks the head move).
  logic            rec_v_q;
  logic [LVL_W-1:0] rec_level_q;
  logic [HID_W-1:0] rec_hart_q;
  logic [CKPT_DEPTH-1:0] rec_oh_q;
  logic [NH-1:0]        rec_hoh_q;

  assign map_q_o = map_q;
  assign fmap_q_o = fmap_q;
  assign free_q_o = free_q;
  assign ffree_q_o = ffree_q;
  assign busy_q_o = busy_q;
  assign fbusy_q_o = fbusy_q;
  assign ckpt_cnt_q_o = ckpt_cnt_q;
  assign ckpt_head_q_o = ckpt_head_q;
  assign recovering_o = mispredict_i || rec_v_q;

  // Recovery select, combinationally identical to the unbanked level math.
  logic [LVL_W-1:0] sel_level;
  logic [HID_W-1:0] sel_hart;
  logic             sel_take;
  // hyp8: the checkpoint-select cone read ckpt_hart_q/ckpt_head_q/
  // ckpt_cnt_q through dynamic indices chained one after another
  // (level -> hart -> head/cnt -> slot). Replaced by a one-hot decode of
  // the clamped level + masked-OR gathers; the wrap/clamp arithmetic is
  // unchanged.
  logic [CKPT_DEPTH-1:0]              lvl_oh;
  logic [NH-1:0]                      mh_oh;
  logic [HID_W-1:0]                   mis_hart_g;
  logic [$clog2(CKPT_DEPTH+1)-1:0]    head_m, cnt_m;
  logic [HID_W-1:0][CKPT_DEPTH-1:0]   hart_t;
  logic [$clog2(CKPT_DEPTH+1)-1:0][NH-1:0] head_t, cnt_t;
  for (genvar s = 0; s < CKPT_DEPTH; s++)
    for (genvar b = 0; b < HID_W; b++)
      assign hart_t[b][s] = ckpt_hart_q[s][b];
  for (genvar h = 0; h < NH; h++)
    for (genvar b = 0; b < $clog2(CKPT_DEPTH+1); b++) begin : gen_hct
      assign head_t[b][h] = ckpt_head_q[h][b];
      assign cnt_t[b][h]  = ckpt_cnt_q[h][b];
    end
  for (genvar s = 0; s < CKPT_DEPTH; s++) begin : gen_lvloh
    if (s == 0) begin : gen_s0
      // out-of-range levels clamp to slot 0, as the original index did
      assign lvl_oh[0] = (int'(mispredict_level_i) >= CKPT_DEPTH) ||
                         (mispredict_level_i == LVL_W'(0));
    end else begin : gen_sx
      assign lvl_oh[s] = (mispredict_level_i == LVL_W'(s)) &&
                         (int'(mispredict_level_i) < CKPT_DEPTH);
    end
  end
  for (genvar b = 0; b < HID_W; b++) begin : gen_mhg
    assign mis_hart_g[b] = |(lvl_oh & hart_t[b]);
  end
  for (genvar h = 0; h < NH; h++) begin : gen_mhoh
    assign mh_oh[h] = (mis_hart_g == HID_W'(h));
  end
  for (genvar b = 0; b < $clog2(CKPT_DEPTH+1); b++) begin : gen_mg
    assign head_m[b] = |(mh_oh & head_t[b]);
    assign cnt_m[b]  = |(mh_oh & cnt_t[b]);
  end

  // hyp8 r5: the unwind depth is the target slot's registered ring index
  // (pos_q), gathered one-hot by lvl_oh -- identical to the original
  // (level-base-head) mod-CPH arithmetic, evaluated per slot off the
  // mispredict path. The resolved slot is itself one-hot: the unique slot
  // in the hart's slice whose ring index equals the clamped target
  // position (slot ring indices are a rotation of the slice, hence
  // pairwise distinct).
  logic [LVL_W-1:0]                rel_g, tgt_pos;
  logic [CKPT_DEPTH-1:0]           tgt_oh;
  logic [LVL_W-1:0][CKPT_DEPTH-1:0] pos_t;
  for (genvar s = 0; s < CKPT_DEPTH; s++)
    for (genvar b = 0; b < LVL_W; b++) begin : gen_post
      assign pos_t[b][s] = pos_q[s][b];
    end
  for (genvar b = 0; b < LVL_W; b++) begin : gen_relg
    assign rel_g[b] = |(lvl_oh & pos_t[b]);
  end
  for (genvar s = 0; s < CKPT_DEPTH; s++) begin : gen_tgtoh
    localparam int unsigned H_S = s / CKPT_PER_HART;
    assign tgt_oh[s] = (mis_hart_g == HID_W'(H_S)) &&
                       (pos_q[s] == tgt_pos);
  end
  always_comb begin
    automatic int unsigned tgt;
    // Same clamp as the original arithmetic: an out-of-range level or a
    // ring position beyond the live count unwinds to the youngest live
    // checkpoint (cnt-1).
    tgt = (int'(mispredict_level_i) >= CKPT_DEPTH)
          ? (int'(cnt_m) - 1)
          : ((int'(rel_g) >= int'(cnt_m)) ? (int'(cnt_m) - 1)
                                          : int'(rel_g));
    tgt_pos   = LVL_W'(tgt);
    sel_hart  = mis_hart_g;
    sel_take  = mispredict_i && (cnt_m != 0);
    sel_level = '0;
    for (int unsigned s = 0; s < CKPT_DEPTH; s++)
      if (tgt_oh[s]) sel_level = sel_level | LVL_W'(s);
  end

  // Live checkpoint slots per hart (ring window [head, head+cnt) of the
  // hart's static slice; the slice index is found by comparison, not by a
  // variable divide).
  function automatic logic live_slot(input int unsigned s);
    automatic int unsigned h, base, off;
    h = 0;
    for (int unsigned hh = 1; hh < NH; hh++)
      if (s >= int'(hh) * CKPT_PER_HART) h = hh;
    base = h * CKPT_PER_HART;
    off = (s - base >= int'(ckpt_head_q[h]))
          ? (s - base - int'(ckpt_head_q[h]))
          : (s - base + CKPT_PER_HART - int'(ckpt_head_q[h]));
    return (off < int'(ckpt_cnt_q[h])) && (h < NH);
  endfunction

  // hyp8 r5: repair-time one-hot payload gathers -- masked-OR over the
  // registered slot one-hot (rec_oh_q) and hart one-hot (rec_hoh_q),
  // replacing every dynamic-index read the serial repair made into the
  // checkpoint arrays.
  logic [PRF_ENTRIES-1:0]   g_alloc;
  logic [FPN-1:0]           g_falloc;
  logic [31:0][PRF_W-1:0]   g_map;
  logic [31:0][FPRF_W-1:0]  g_fmap;
  logic [HID_W-1:0]         g_hart;
  logic [LVL_W-1:0]         g_pos, g_cnt;
  for (genvar i = 0; i < PRF_ENTRIES; i++) begin : gen_galloc
    logic [CKPT_DEPTH-1:0] col;
    for (genvar s = 0; s < CKPT_DEPTH; s++)
      assign col[s] = ckpt_alloc_q[s][i];
    assign g_alloc[i] = |(rec_oh_q & col);
  end
  for (genvar i = 0; i < FPN; i++) begin : gen_gfalloc
    logic [CKPT_DEPTH-1:0] col;
    for (genvar s = 0; s < CKPT_DEPTH; s++)
      assign col[s] = ckpt_falloc_q[s][i];
    assign g_falloc[i] = |(rec_oh_q & col);
  end
  for (genvar a = 0; a < 32; a++) begin : gen_gmap
    for (genvar b = 0; b < PRF_W; b++) begin : gen_gm
      logic [CKPT_DEPTH-1:0] col;
      for (genvar s = 0; s < CKPT_DEPTH; s++)
        assign col[s] = ckpt_map_q[s][a][b];
      assign g_map[a][b] = |(rec_oh_q & col);
    end
    for (genvar b = 0; b < FPRF_W; b++) begin : gen_gfm
      logic [CKPT_DEPTH-1:0] col;
      for (genvar s = 0; s < CKPT_DEPTH; s++)
        assign col[s] = ckpt_fmap_q[s][a][b];
      assign g_fmap[a][b] = |(rec_oh_q & col);
    end
  end
  for (genvar b = 0; b < HID_W; b++) begin : gen_ghart
    logic [CKPT_DEPTH-1:0] col;
    for (genvar s = 0; s < CKPT_DEPTH; s++)
      assign col[s] = ckpt_hart_q[s][b];
    assign g_hart[b] = |(rec_oh_q & col);
  end
  for (genvar b = 0; b < LVL_W; b++) begin : gen_gpos
    assign g_pos[b] = |(rec_oh_q & pos_t[b]);
    assign g_cnt[b] = |(rec_hoh_q & cnt_t[b]);
  end

  // Per-hart retirement counters for the next-state process below --
  // module-scope array so no shared automatic scalar is reused across
  // loop iterations.
  int unsigned n_ret[NH];

  // Slots reserved by the publishing group this cycle.
  logic [CKPT_DEPTH-1:0] rsvd_mask;
  always_comb begin
    rsvd_mask = '0;
    if (pub_v_i) begin
      for (int unsigned p = 0; p < NR_PORTS; p++)
        if (pub_ck_v_i[p] && (int'(pub_ck_slot_i[p]) < CKPT_DEPTH))
          rsvd_mask[pub_ck_slot_i[p]] = 1'b1;
    end
  end

  // hyp8 T1 item 9: row-local publish marks. The live-slot test is
  // evaluated per slot with the slot's static slice owner (slices are
  // contiguous fixed ranges, so the hart a slot belongs to is a constant,
  // clamped to the last hart for a stray slot beyond NH*CKPT_PER_HART —
  // identical to live_slot's largest-hh rule); the checkpoint write hit
  // is a one-hot slot decode per port instead of a dynamic-index write
  // (rsvd_mask[s] and a port hit are the same predicate), and the
  // per-slot mark/write values are masked-OR columns rather than
  // mux-selected reads.
  logic [NR_PORTS-1:0][CKPT_DEPTH-1:0] pub_ck_oh;
  logic [CKPT_DEPTH-1:0][NR_PORTS-1:0] pub_ck_oh_t;
  for (genvar p = 0; p < NR_PORTS; p++)
    for (genvar s = 0; s < CKPT_DEPTH; s++) begin
      assign pub_ck_oh[p][s] =
          pub_ck_v_i[p] && (int'(pub_ck_slot_i[p]) == s);
      assign pub_ck_oh_t[s][p] = pub_ck_oh[p][s];
    end

  logic [CKPT_DEPTH-1:0]                 t1_live_s, t1_wr_s;
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0] t1_aval_s, t1_mk_s;
  logic [CKPT_DEPTH-1:0][FPN-1:0]        t1_faval_s, t1_fmk_s;
  logic [CKPT_DEPTH-1:0][HID_W-1:0]      t1_hart_s;
  for (genvar s = 0; s < CKPT_DEPTH; s++) begin : gen_pub_row
    localparam int unsigned HS =
        (s / CKPT_PER_HART < NH) ? s / CKPT_PER_HART : NH - 1;
    localparam int unsigned BASE = HS * CKPT_PER_HART;
    assign t1_live_s[s] =
        (((int'(s) - int'(BASE)) >= int'(ckpt_head_q[HS]))
          ? (int'(s) - int'(BASE) - int'(ckpt_head_q[HS]))
          : (int'(s) - int'(BASE) + int'(CKPT_PER_HART) -
             int'(ckpt_head_q[HS])))
        < int'(ckpt_cnt_q[HS]);
    assign t1_wr_s[s] = pub_v_i && (|pub_ck_oh_t[s]);
    for (genvar i = 0; i < PRF_ENTRIES; i++) begin : gen_av
      logic [NR_PORTS-1:0] vcol;
      logic [NH-1:0]       mcol;
      for (genvar p = 0; p < NR_PORTS; p++)
        assign vcol[p] = pub_ck_oh[p][s] && pub_ck_aval_i[p][i];
      for (genvar h = 0; h < NH; h++)
        assign mcol[h] = (ckpt_hart_q[s] == HID_W'(h)) && pub_mark_i[h][i];
      assign t1_aval_s[s][i] = |vcol;
      assign t1_mk_s[s][i]   = |mcol;
    end
    for (genvar i = 0; i < FPN; i++) begin : gen_fav
      logic [NR_PORTS-1:0] vcol;
      logic [NH-1:0]       mcol;
      for (genvar p = 0; p < NR_PORTS; p++)
        assign vcol[p] = pub_ck_oh[p][s] && pub_ck_faval_i[p][i];
      for (genvar h = 0; h < NH; h++)
        assign mcol[h] = (ckpt_hart_q[s] == HID_W'(h)) && pub_fmark_i[h][i];
      assign t1_faval_s[s][i] = |vcol;
      assign t1_fmk_s[s][i]   = |mcol;
    end
    for (genvar b = 0; b < HID_W; b++) begin : gen_hb
      logic [NR_PORTS-1:0] hcol;
      for (genvar p = 0; p < NR_PORTS; p++)
        assign hcol[p] = pub_ck_oh[p][s] && pub_ck_h_i[p][b];
      assign t1_hart_s[s][b] = |hcol;
    end
  end

  // hyp8 T1 item 9: post-publish next row values, computed as a live row
  // vector so the equivalence tap below is a plain continuous read of the
  // live path rather than a conditional write inside p_next_state.
  // Per slot: write hit -> port value, else live -> OR the hart's mark,
  // else hold -- identical to the per-slot arm applied in p_next_state.
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0] pub_alloc_v;
  logic [CKPT_DEPTH-1:0][FPN-1:0]         pub_falloc_v;
  logic [CKPT_DEPTH-1:0][HID_W-1:0]       pub_hart_v;
  for (genvar s = 0; s < CKPT_DEPTH; s++) begin : gen_pub_v
    assign pub_alloc_v[s]  = t1_wr_s[s]   ? t1_aval_s[s] :
                             t1_live_s[s] ? (ckpt_alloc_q[s] | t1_mk_s[s])
                                         : ckpt_alloc_q[s];
    assign pub_falloc_v[s] = t1_wr_s[s]   ? t1_faval_s[s] :
                             t1_live_s[s] ? (ckpt_falloc_q[s] | t1_fmk_s[s])
                                         : ckpt_falloc_q[s];
    assign pub_hart_v[s]   = t1_wr_s[s]   ? t1_hart_s[s] : ckpt_hart_q[s];
  end

  always_comb begin : p_next_state
    automatic logic [PRF_ENTRIES-1:0] squashed, arch_ref, free_rep;
    automatic logic [FPN-1:0] fsquashed, farch_ref, ffree_rep;
    automatic int unsigned rel2;
    automatic logic [LVL_W:0] adv_h;
    map_d = map_q;
    amap_d = amap_q;
    free_d = free_q;
    busy_d = busy_q;
    owner_d = owner_q;
    fowner_d = fowner_q;
    fmap_d = fmap_q;
    famap_d = famap_q;
    ffree_d = ffree_q;
    fbusy_d = fbusy_q;
    ckpt_head_d = ckpt_head_q;
    ckpt_cnt_d = ckpt_cnt_q;
    ckpt_alloc_d = ckpt_alloc_q;
    ckpt_falloc_d = ckpt_falloc_q;
    ckpt_hart_d = ckpt_hart_q;
    squashed = '0; arch_ref = '0; free_rep = '0;
    fsquashed = '0; farch_ref = '0; ffree_rep = '0;
    rel2 = 0;
    for (int unsigned h = 0; h < NH; h++) n_ret[h] = 0;

    // ---- publish -----------------------------------------------------
    if (pub_v_i) begin
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (pub_map_wr_v_i[p])
          map_d[pub_map_h_i[p]][pub_map_rd_i[p]] =
              PRF_W'(pub_map_prd_i[p][PRF_W-1:0]);
        if (pub_fmap_wr_v_i[p])
          fmap_d[pub_map_h_i[p]][pub_map_rd_i[p]] =
              FPRF_W'(pub_fmap_prd_i[p][FPRF_W-1:0]);
        if (pub_own_v_i[p])
          owner_d[int'(pub_own_idx_i[p])] = HID_W'(pub_own_h_i[p]);
        if (pub_fown_v_i[p])
          fowner_d[int'(pub_fown_idx_i[p])] = HID_W'(pub_own_h_i[p]);
      end
      busy_d  = busy_d  | pub_busy_set_i;
      fbusy_d = fbusy_d | pub_fbusy_set_i;
`ifdef G6LC_MUT_T1_RNREC
      // Review mutant: pre-T1 publish section — per-entry live_slot loop
      // plus dynamic-index writes, restored on the live path.
      for (int unsigned s = 0; s < CKPT_DEPTH; s++) begin
        if (live_slot(s) && !rsvd_mask[s]) begin
          ckpt_alloc_d[s]  = ckpt_alloc_d[s]  | pub_mark_i[ckpt_hart_q[s]];
          ckpt_falloc_d[s] = ckpt_falloc_d[s] | pub_fmark_i[ckpt_hart_q[s]];
        end
      end
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (pub_ck_v_i[p] && (int'(pub_ck_slot_i[p]) < CKPT_DEPTH)) begin
          ckpt_hart_d[pub_ck_slot_i[p]]   = HID_W'(pub_ck_h_i[p]);
          ckpt_alloc_d[pub_ck_slot_i[p]]  = pub_ck_aval_i[p];
          ckpt_falloc_d[pub_ck_slot_i[p]] = pub_ck_faval_i[p];
        end
      end
`else
      // hyp8 T1 item 9: per-slot exclusive arms applied as one row
      // vector. A write hit and a reservation are the same decoded
      // predicate (t1_wr_s), so the two old loops collapse into the
      // pub_*_v rows: hit → port value, else live → OR the hart's mark,
      // else hold.
      ckpt_hart_d   = pub_hart_v;
      ckpt_alloc_d  = pub_alloc_v;
      ckpt_falloc_d = pub_falloc_v;
`endif
    end

    // ---- reserve ------------------------------------------------------
    if (res_v_i) begin
      free_d  = free_d  & ~res_pick_mask_i;
      ffree_d = ffree_d & ~res_fpick_mask_i;
      for (int unsigned h = 0; h < NH; h++)
        ckpt_cnt_d[h] = ckpt_cnt_d[h] + res_br_inc_i[h];
    end

    // ---- writeback busy clears ----------------------------------------
    for (int unsigned w = 0; w < NR_WB; w++) begin
      if (wb_valid_i[w] && wb_prd_i[w] != '0) busy_d[wb_prd_i[w]] = 1'b0;
      if (FP_EN && fwb_valid_i[w]) fbusy_d[fwb_prd_i[w]] = 1'b0;
    end

    // ---- commit frees --------------------------------------------------
    for (int unsigned f = 0; f < NR_FREE; f++) begin
      if (free_i[f] && free_prd_i[f] != '0) begin
        free_d[free_prd_i[f]] = 1'b1;
        busy_d[free_prd_i[f]] = 1'b0;
      end
      if (FP_EN && ffree_i[f]) begin
        ffree_d[ffree_prd_i[f]] = 1'b1;
        fbusy_d[ffree_prd_i[f]] = 1'b0;
      end
    end

    // ---- killed in-flight group: return its reservations exactly once --
    if (kill_v_i) begin
      free_d  = free_d  | kill_pick_mask_i;
      ffree_d = ffree_d | kill_fpick_mask_i;
    end

    // Repair basis: everything currently free, commit frees and killed-
    // group returns included (the unbanked free_rep = free + this-cycle
    // frees; in-flight reservations are not free yet and are never in the
    // checkpoint alloc masks, so they stay excluded either way).
    free_rep  = free_d;
    ffree_rep = ffree_d;

    // ---- registered mispredict repair ----------------------------------
    // Select was registered last cycle; the squash set is the checkpoint's
    // alloc mask minus everything already free. Restore the map, repair --
    // never reinstate -- free/busy, and unwind that hart's ring to the
    // restored level.
    // hyp8 r5: one-hot restore -- the payload columns are gathered by
    // masked-OR on the registered slot one-hot; the unwind count is the
    // slot's registered ring index re-gathered at repair time (retire
    // drift already folded into pos_q), clamped to the live count exactly
    // as the arithmetic form did.
    if (rec_v_q) begin
      // g_pos < g_cnt: the selected checkpoint is still inside the
      // CURRENT live ring (pos_q was updated from head_d at the last
      // edge). Outside it, every older checkpoint retired between
      // select and repair, so the surviving older count is 0 -- the
      // old g_cnt-1 clamp underflowed when g_cnt was already 0.
      rel2 = (int'(g_pos) < int'(g_cnt)) ? int'(g_pos) : 0;
      squashed = g_alloc & ~free_rep;
      map_d[g_hart] = g_map;
      free_d = free_d | squashed;
      busy_d = busy_d & ~squashed;
      if (FP_EN) begin
        fsquashed = g_falloc & ~ffree_rep;
        fmap_d[g_hart] = g_fmap;
        ffree_d = ffree_d | fsquashed;
        fbusy_d = fbusy_d & ~fsquashed;
      end
      ckpt_cnt_d[rec_hart_q] = LVL_W'(rel2);
    end

    // ---- checkpoint retire ---------------------------------------------
    for (int unsigned h = 0; h < NH; h++) begin
      for (int unsigned c = 0; c < NR_FREE; c++)
        if (ckpt_retire_i[c] && (int'(commit_hart_i[c]) == h)) n_ret[h]++;
      if (n_ret[h] > int'(ckpt_cnt_d[h])) n_ret[h] = int'(ckpt_cnt_d[h]);
      // Head is already the offset in this hart's ring. ckpt_slot added the
      // hart base and this subtract removed it. n_ret fits in the live count,
      // so one subtract wraps the sum.
      adv_h = {1'b0, ckpt_head_q[h]} + (LVL_W + 1)'(n_ret[h]);
      ckpt_head_d[h] = (adv_h >= (LVL_W + 1)'(CKPT_PER_HART))
          ? LVL_W'(adv_h - (LVL_W + 1)'(CKPT_PER_HART))
          : adv_h[LVL_W-1:0];
      ckpt_cnt_d[h]  = ckpt_cnt_d[h] - LVL_W'(n_ret[h]);
    end

    // ---- architectural-map commit updates ------------------------------
    for (int unsigned c = 0; c < NR_FREE; c++) begin
      if (FP_EN && commit_valid_i[c] && commit_is_fpr_i[c])
        famap_d[commit_hart_i[c]][commit_rd_i[c]] = commit_fprd_i[c];
      else if (commit_valid_i[c] && (commit_rd_i[c] != 5'd0) &&
               (commit_prd_i[c] != '0))
        amap_d[commit_hart_i[c]][commit_rd_i[c]] = commit_prd_i[c];
    end

    // ---- per-hart flush -------------------------------------------------
    for (int unsigned h = 0; h < NH; h++) begin
      if (flush_hart_i[h] && !flush_i) begin
        arch_ref = '0;
        for (int unsigned a = 0; a < 32; a++)
          if (amap_d[h][a] != '0) arch_ref[amap_d[h][a]] = 1'b1;
        map_d[h] = amap_d[h];
        for (int unsigned i = 1; i < PRF_ENTRIES; i++) begin
          if ((int'(owner_d[i]) == h) && !arch_ref[i]) begin
            free_d[i] = 1'b1;
            busy_d[i] = 1'b0;
          end
        end
        if (FP_EN) begin
          farch_ref = '0;
          for (int unsigned a = 0; a < 32; a++) farch_ref[famap_d[h][a]] = 1'b1;
          fmap_d[h] = famap_d[h];
          for (int unsigned i = 0; i < FPN; i++) begin
            if ((int'(fowner_d[i]) == h) && !farch_ref[i]) begin
              ffree_d[i] = 1'b1;
              fbusy_d[i] = 1'b0;
            end
          end
        end
        ckpt_head_d[h] = '0;
        ckpt_cnt_d[h]  = '0;
      end
    end

    // ---- full flush -----------------------------------------------------
    if (flush_i) begin
      map_d  = amap_d;
      free_d = '0;
      for (int unsigned i = 1; i < PRF_ENTRIES; i++) free_d[i] = 1'b1;
      for (int unsigned h = 0; h < NH; h++)
        for (int unsigned a = 0; a < 32; a++)
          if (amap_d[h][a] != '0) free_d[amap_d[h][a]] = 1'b0;
      busy_d = '0;
      ckpt_head_d = '0;
      ckpt_cnt_d  = '0;
      if (FP_EN) begin
        fmap_d  = famap_d;
        ffree_d = '1;
        for (int unsigned h = 0; h < NH; h++)
          for (int unsigned a = 0; a < 32; a++) ffree_d[famap_d[h][a]] = 1'b0;
        fbusy_d = '0;
      end
    end
  end

  // hyp8 r5: ring-index next-state -- every slot's position against the
  // post-edge head (retire/unwind drift folded in once, per slot, off the
  // restore path). pos values are a rotation of the slice, hence distinct.
  for (genvar s = 0; s < CKPT_DEPTH; s++) begin : gen_posd
    localparam int unsigned H_S   = s / CKPT_PER_HART;
    localparam int unsigned OFF_S = s - H_S * CKPT_PER_HART;
    assign pos_d[s] = (OFF_S >= int'(ckpt_head_d[H_S]))
        ? LVL_W'(OFF_S - int'(ckpt_head_d[H_S]))
        : LVL_W'(OFF_S + CKPT_PER_HART - int'(ckpt_head_d[H_S]));
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned h = 0; h < NH; h++) begin
        map_q[h][0]  <= '0;
        amap_q[h][0] <= '0;
        for (int unsigned i = 1; i < 32; i++) begin
          map_q[h][i]  <= PRF_W'(31 * h + i);
          amap_q[h][i] <= PRF_W'(31 * h + i);
        end
      end
      free_q <= '0;
      for (int unsigned i = 31 * NH + 1; i < PRF_ENTRIES; i++) free_q[i] <= 1'b1;
      owner_q <= '0;
      for (int unsigned h = 0; h < NH; h++)
        for (int unsigned i = 1; i < 32; i++) owner_q[31 * h + i] <= HID_W'(h);
      ckpt_hart_q <= '0;
      ffree_q <= '0;
      fbusy_q <= '0;
      for (int unsigned i = 0; i < FPN; i++) fowner_q[i] <= HID_W'(i / 32);
      ckpt_fmap_q <= '0;
      ckpt_falloc_q <= '0;
      for (int unsigned h = 0; h < NH; h++)
        for (int unsigned i = 0; i < 32; i++) begin
          fmap_q[h][i]  <= FPRF_W'(32 * h + i);
          famap_q[h][i] <= FPRF_W'(32 * h + i);
        end
      for (int unsigned i = 32 * NH; i < FPN; i++) ffree_q[i] <= 1'b1;
      busy_q <= '0;
      ckpt_head_q <= '0;
      ckpt_cnt_q <= '0;
      ckpt_map_q <= '0;
      ckpt_alloc_q <= '0;
      rec_v_q <= 1'b0;
      rec_level_q <= '0;
      rec_hart_q <= '0;
      rec_oh_q <= '0;
      rec_hoh_q <= '0;
      pos_q <= '0;
    end else begin
      map_q <= map_d;
      amap_q <= amap_d;
      free_q <= free_d;
      busy_q <= busy_d;
      ckpt_head_q <= ckpt_head_d;
      ckpt_cnt_q <= ckpt_cnt_d;
      ckpt_alloc_q <= ckpt_alloc_d;
      ckpt_hart_q <= ckpt_hart_d;
      owner_q <= owner_d;
      fowner_q <= fowner_d;
      fmap_q <= fmap_d;
      famap_q <= famap_d;
      ffree_q <= ffree_d;
      fbusy_q <= fbusy_d;
      ckpt_falloc_q <= ckpt_falloc_d;
      pos_q <= pos_d;
      // Checkpoint payloads land at publish (the unbanked design wrote them
      // under do_ckpt in the same edge as the rest).
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (pub_v_i && pub_ck_v_i[p] && (int'(pub_ck_slot_i[p]) < CKPT_DEPTH)) begin
          ckpt_fmap_q[pub_ck_slot_i[p]] <= pub_ck_fmap_i[p];
          ckpt_map_q[pub_ck_slot_i[p]]  <= pub_ck_map_i[p];
        end
      end
      if (flush_i) begin
        rec_v_q <= 1'b0;
      end else if (mispredict_i) begin
        rec_v_q     <= sel_take;
        rec_level_q <= sel_level;
        rec_hart_q  <= sel_hart;
        rec_oh_q    <= tgt_oh;
        for (int unsigned h = 0; h < NH; h++)
          rec_hoh_q[h] <= (sel_hart == HID_W'(h));
      end else begin
        rec_v_q <= 1'b0;
      end
    end
  end

  // pragma translate_off
  // ----------------------------------------------------------------------
  // hyp8 r5 equivalence reference: the arithmetic checkpoint select and
  // restore, verbatim from the pre-restructure form.
  //   ref_* : the original (level-base-head) mod-CPH unwind arithmetic
  //           plus the ckpt_slot reconstruction -- asserted against the
  //           one-hot select outputs on every mispredict_i.
  //   ref_rel2 : the original repair-time unwind-depth re-derivation on
  //           the registered slot vs the live head/cnt -- asserted
  //           against the registered ring-index gather + clamp.
  //   The payload-gather asserts prove each masked-OR column read equals
  //   the original dynamic-index array read on the registered slot.
  logic [LVL_W-1:0] ref_level;
  logic [HID_W-1:0] ref_hart;
  logic             ref_take;
  logic [LVL_W-1:0] ref_rel2;
  always_comb begin
    automatic int unsigned rel, mis_hart, lvl_rel;
    mis_hart = int'(mis_hart_g);
    lvl_rel = (int'(mispredict_level_i) < CKPT_DEPTH)
              ? (int'(mispredict_level_i) - mis_hart * CKPT_PER_HART)
              : CKPT_PER_HART;
    rel = (lvl_rel >= int'(head_m))
          ? (lvl_rel - int'(head_m))
          : (lvl_rel + CKPT_PER_HART - int'(head_m));
    if ((lvl_rel >= CKPT_PER_HART) || (rel >= int'(cnt_m)))
      rel = int'(cnt_m) - 1;
    ref_hart  = mis_hart_g;
    ref_level = ckpt_slot(mis_hart, int'(head_m) + rel);
    ref_take  = mispredict_i && (cnt_m != 0);
  end
  always_comb begin
    automatic int unsigned lbase, loff, r2;
    lbase = int'(rec_hart_q) * CKPT_PER_HART;
    loff = (int'(rec_level_q) >= lbase) ? (int'(rec_level_q) - lbase) : 0;
    r2 = (loff >= int'(ckpt_head_q[rec_hart_q]))
         ? (loff - int'(ckpt_head_q[rec_hart_q]))
         : (loff + CKPT_PER_HART - int'(ckpt_head_q[rec_hart_q]));
    // Outside the live ring means every older checkpoint already
    // retired: the arithmetic reference of the repair unwind is 0.
    if (r2 >= int'(ckpt_cnt_q[rec_hart_q])) r2 = 0;
    ref_rel2 = LVL_W'(r2);
  end
  // The select is only consumed when ref_take (cnt_m != 0): on an empty
  // ring the arithmetic reference's rel = cnt_m-1 underflows unsigned and
  // ref_level is garbage, while the one-hot form cleanly produces no slot
  // match (sel_level '0, sel_take 0) -- the level is then don't-care, so
  // equivalence is only owed when the select is taken.
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      ref_take |-> (sel_level == ref_level) && (sel_hart == ref_hart) &&
                   (sel_take == ref_take))
    else $fatal(1, "rename_recover: one-hot select != arithmetic select (sel=%0d ref=%0d lvl=%0d hart=%0d cnt=%0d head=%0d)",
                sel_level, ref_level, mispredict_level_i, mis_hart_g, cnt_m, head_m);
  // Void-select evidence: a mispredict on an empty ring exercises the gate
  // above; log when the underflowed reference diverged so the run shows the
  // leg was taken rather than the check being silent.
  always @(posedge clk_i) begin
    if (rst_ni && mispredict_i && !ref_take && (sel_level != ref_level))
      $display("[%0t] rename_recover: void select on empty ring: lvl=%0d sel_level=%0d ref_level=%0d cnt=%0d head=%0d",
               $time, mispredict_level_i, sel_level, ref_level, cnt_m, head_m);
  end
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      rec_v_q |-> (g_alloc == ckpt_alloc_q[rec_level_q]) &&
                  (g_hart  == ckpt_hart_q[rec_level_q]) &&
                  (g_map   == ckpt_map_q[rec_level_q]))
    else $fatal(1, "rename_recover: repair gather != indexed read");
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      (rec_v_q && FP_EN) |-> (g_falloc == ckpt_falloc_q[rec_level_q]) &&
                             (g_fmap   == ckpt_fmap_q[rec_level_q]))
    else $fatal(1, "rename_recover: FP repair gather != indexed read");
  assert property (@(posedge clk_i) disable iff (!rst_ni)
      rec_v_q |-> (ref_rel2 == ((int'(g_pos) < int'(g_cnt))
                                ? g_pos : LVL_W'(0))) &&
                  (g_cnt == ckpt_cnt_q[rec_hart_q]))
    else $fatal(1, "rename_recover: one-hot unwind depth != arithmetic");
  for (genvar h = 0; h < NH; h++) begin : gen_ckpt_cnt_chk
    assert property (@(posedge clk_i) disable iff (!rst_ni)
        int'(ckpt_cnt_q[h]) <= CKPT_PER_HART)
      else $fatal(1, "rename_recover: checkpoint count exceeds ring");
  end
  // Physical register 0 is the permanent x0 mapping and must never be busy:
  // need_rd is 0 for any rd==0 int destination (dispatch), the freelist
  // never returns tag 0, and the WB clear is prd!='0-gated. FP p0 is a real
  // register (f0) -- fbusy_q is intentionally unchecked.
  assert property (@(posedge clk_i) disable iff (!rst_ni) !busy_q[0])
    else $fatal(1, "rename_recover: int busy[0] set (x0 physical tag marked busy)");

  // hyp8 T1 item 9: row-local publish equivalence — the pre-T1 loop form
  // (live_slot mark-OR + dynamic-index writes) is recomputed from the
  // registered state and compared every cycle against the live path's
  // post-publish rows (pub_*_v are the actual nets p_next_state applies).
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0] t1_pub_alloc_tap;
  logic [CKPT_DEPTH-1:0][FPN-1:0]         t1_pub_falloc_tap;
  logic [CKPT_DEPTH-1:0][HID_W-1:0]       t1_pub_hart_tap;
  assign t1_pub_alloc_tap  = pub_alloc_v;
  assign t1_pub_falloc_tap = pub_falloc_v;
  assign t1_pub_hart_tap   = pub_hart_v;
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0] t1_ref_alloc;
  logic [CKPT_DEPTH-1:0][FPN-1:0]         t1_ref_falloc;
  logic [CKPT_DEPTH-1:0][HID_W-1:0]       t1_ref_hart;
  always_comb begin : p_t1_rnrec_ref
    t1_ref_alloc  = ckpt_alloc_q;
    t1_ref_falloc = ckpt_falloc_q;
    t1_ref_hart   = ckpt_hart_q;
    if (pub_v_i) begin
      for (int unsigned s = 0; s < CKPT_DEPTH; s++) begin
        if (live_slot(s) && !rsvd_mask[s]) begin
          t1_ref_alloc[s]  = t1_ref_alloc[s]  | pub_mark_i[ckpt_hart_q[s]];
          t1_ref_falloc[s] = t1_ref_falloc[s] | pub_fmark_i[ckpt_hart_q[s]];
        end
      end
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (pub_ck_v_i[p] && (int'(pub_ck_slot_i[p]) < CKPT_DEPTH)) begin
          t1_ref_hart[pub_ck_slot_i[p]]   = HID_W'(pub_ck_h_i[p]);
          t1_ref_alloc[pub_ck_slot_i[p]]  = pub_ck_aval_i[p];
          t1_ref_falloc[pub_ck_slot_i[p]] = pub_ck_faval_i[p];
        end
      end
    end
  end
  int unsigned t1_rnrec_n = 0;
  always_ff @(posedge clk_i) begin : p_t1_rnrec_eq
    if (rst_ni) begin
      if (pub_v_i && !$isunknown({t1_pub_alloc_tap, t1_pub_falloc_tap,
                       t1_pub_hart_tap})) begin
        t1_rnrec_n <= t1_rnrec_n + 1;
        g6lc_t1_rnrec_eq: assert (
            (t1_pub_alloc_tap  === t1_ref_alloc) &&
            (t1_pub_falloc_tap === t1_ref_falloc) &&
            (t1_pub_hart_tap   === t1_ref_hart))
          else $error("g6lc_rename_recover: equiv pubmarks");
      end
    end
  end
  final begin
    if ($test$plusargs("equiv_report"))
      $display("[equiv] g6lc_rename_recover pubmarks: checked=%0d",
               t1_rnrec_n);
  end
  // pragma translate_on

endmodule
