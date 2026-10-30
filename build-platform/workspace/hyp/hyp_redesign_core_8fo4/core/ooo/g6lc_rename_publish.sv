// hyp8 provenance: REWRITTEN (rename stage R3 -- publish)
// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// g6lc_rename_publish -- R3 of the staged rename (analysis/g6lc_rename.md).
// Applies the resolved group to the state core's update port:
//   * destination map writes (integer and FP, last lane wins per
//     (hart, rd) -- the unbanked sequential map_d order),
//   * busy-set masks for the picked physicals,
//   * ownership writes for the shared pool's per-hart reclaim,
//   * branch checkpoint capture: each branch lane snapshots the map AS OF
//     its own position in the group (post-rename for every lane up to and
//     including itself), so a later mispredict unwinds to exactly that
//     point,
//   * checkpoint alloc marks: a pick marks every live checkpoint slot of
//     its own hart except a same-group branch's new slot, which starts
//     empty and collects only younger lanes' picks -- the unbanked order
//     (alloc marks before branch slots reset, per lane, in lane order).
//
// The write VALUES are produced combinationally; the state core applies
// them in one always_comb alongside WB clears, commit frees and recovery,
// in the same priority order as the unbanked single-cycle form.

module g6lc_rename_publish
  import g6lc_ooo_pkg::*;
#(
    parameter int unsigned PRF_ENTRIES  = 72,
    parameter int unsigned PRF_W        = 7,
    parameter int unsigned NR_PORTS     = 2,
    parameter int unsigned NR_HARTS     = 1,
    parameter int unsigned CKPT_DEPTH   = 8,
    parameter int unsigned FPRF_ENTRIES = 0,
    parameter int unsigned FPRF_W       = 1
) (
    input  ooo_ren_lane_t [NR_PORTS-1:0] lane_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][31:0][PRF_W-1:0]  map_q_i,
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0][31:0][FPRF_W-1:0] fmap_q_i,
    // Group map writes (per lane; recover applies them in lane order).
    output logic [NR_PORTS-1:0]       pub_map_wr_v_o,
    output logic [NR_PORTS-1:0][1:0]  pub_map_h_o,
    output logic [NR_PORTS-1:0][4:0]  pub_map_rd_o,
    output logic [NR_PORTS-1:0][7:0]  pub_map_prd_o,
    output logic [NR_PORTS-1:0]       pub_fmap_wr_v_o,
    output logic [NR_PORTS-1:0][7:0]  pub_fmap_prd_o,
    // Busy-set masks for the picks.
    output logic [PRF_ENTRIES-1:0]    pub_busy_set_o,
    output logic [(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] pub_fbusy_set_o,
    // Ownership writes (picked phys -> owning hart).
    output logic [NR_PORTS-1:0]       pub_own_v_o,
    output logic [NR_PORTS-1:0][7:0]  pub_own_idx_o,
    output logic [NR_PORTS-1:0][1:0]  pub_own_h_o,
    output logic [NR_PORTS-1:0]       pub_fown_v_o,
    output logic [NR_PORTS-1:0][7:0]  pub_fown_idx_o,
    // Branch checkpoint payloads (one per branch lane).
    output logic [NR_PORTS-1:0]       pub_ck_v_o,
    output logic [NR_PORTS-1:0][7:0]  pub_ck_slot_o,
    output logic [NR_PORTS-1:0][1:0]  pub_ck_h_o,
    output logic [NR_PORTS-1:0][31:0][PRF_W-1:0]  pub_ck_map_o,
    output logic [NR_PORTS-1:0][31:0][FPRF_W-1:0] pub_ck_fmap_o,
    output logic [NR_PORTS-1:0][PRF_ENTRIES-1:0] pub_ck_aval_o,
    output logic [NR_PORTS-1:0][(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] pub_ck_faval_o,
    // Alloc marks OR-ed into pre-existing live slots, per hart.
    output logic [(NR_HARTS<1?1:NR_HARTS)-1:0][PRF_ENTRIES-1:0] pub_mark_o,
    output logic [(NR_HARTS<1?1:NR_HARTS)-1:0][(FPRF_ENTRIES<1?1:FPRF_ENTRIES)-1:0] pub_fmark_o
);

  localparam int unsigned NH    = (NR_HARTS < 1) ? 1 : NR_HARTS;
  localparam int unsigned FPN   = (FPRF_ENTRIES < 1) ? 1 : FPRF_ENTRIES;
  localparam bit          FP_EN = (FPRF_ENTRIES >= 32);

  always_comb begin
    automatic logic [NH-1:0][31:0][PRF_W-1:0]  wm;
    automatic logic [NH-1:0][31:0][FPRF_W-1:0] fwm;
    automatic logic [PRF_ENTRIES-1:0] pmask;
    automatic logic [FPN-1:0]         fpmask;

    wm  = map_q_i;
    fwm = fmap_q_i;
    pub_map_wr_v_o = '0;
    pub_map_h_o = '0;
    pub_map_rd_o = '0;
    pub_map_prd_o = '0;
    pub_fmap_wr_v_o = '0;
    pub_fmap_prd_o = '0;
    pub_busy_set_o = '0;
    pub_fbusy_set_o = '0;
    pub_own_v_o = '0;
    pub_own_idx_o = '0;
    pub_own_h_o = '0;
    pub_fown_v_o = '0;
    pub_fown_idx_o = '0;
    pub_ck_v_o = '0;
    pub_ck_slot_o = '0;
    pub_ck_h_o = '0;
    pub_ck_map_o = '0;
    pub_ck_fmap_o = '0;
    pub_ck_aval_o = '0;
    pub_ck_faval_o = '0;
    pub_mark_o = '0;
    pub_fmark_o = '0;

    for (int unsigned p = 0; p < NR_PORTS; p++) begin
      pmask  = '0;
      fpmask = '0;
      if (lane_i[p].v && lane_i[p].do_alloc) begin
        pmask = PRF_ENTRIES'(1) << lane_i[p].prd[$clog2(PRF_ENTRIES > 1 ? PRF_ENTRIES : 2)-1:0];
      end
      if (lane_i[p].v && lane_i[p].do_falloc) begin
        fpmask = FPN'(1) << lane_i[p].fprd[$clog2(FPN > 1 ? FPN : 2)-1:0];
      end

      // hart/rd ride the shared fields for both classes -- set them for
      // every valid lane so an FP-only destination is still addressed.
      if (lane_i[p].v) begin
        pub_map_h_o[p]  = lane_i[p].hart;
        pub_map_rd_o[p] = lane_i[p].rd;
      end
      // Destination map write + busy set + ownership.
      if (lane_i[p].v && lane_i[p].do_alloc) begin
        pub_map_wr_v_o[p] = 1'b1;
        pub_map_prd_o[p]  = lane_i[p].prd;
        wm[lane_i[p].hart][lane_i[p].rd] = PRF_W'(lane_i[p].prd[PRF_W-1:0]);
        pub_busy_set_o |= pmask;
        pub_own_v_o[p]   = 1'b1;
        pub_own_idx_o[p] = lane_i[p].prd;
        pub_own_h_o[p]   = lane_i[p].hart;
        pub_mark_o[lane_i[p].hart] |= pmask;
      end
      if (lane_i[p].v && lane_i[p].do_falloc) begin
        pub_fmap_wr_v_o[p] = 1'b1;
        pub_fmap_prd_o[p]  = lane_i[p].fprd;
        fwm[lane_i[p].hart][lane_i[p].rd] = FPRF_W'(lane_i[p].fprd[FPRF_W-1:0]);
        pub_fbusy_set_o |= fpmask;
        pub_fown_v_o[p]   = 1'b1;
        pub_fown_idx_o[p] = lane_i[p].fprd;
        pub_fmark_o[lane_i[p].hart] |= fpmask;
      end

      // Branch checkpoint: the map as it stands after this lane's own
      // rename -- work at or older than the branch survives the unwind.
      // The slot's alloc mask opens empty; only YOUNGER same-hart lanes
      // accumulate into it (they are the speculation the unwind squashes).
      if (lane_i[p].v && lane_i[p].do_ckpt) begin
        for (int unsigned q = p + 1; q < NR_PORTS; q++) begin
          if (lane_i[q].v && lane_i[q].do_alloc &&
              (lane_i[q].hart == lane_i[p].hart))
            pub_ck_aval_o[p] |= PRF_ENTRIES'(1) <<
                    lane_i[q].prd[$clog2(PRF_ENTRIES > 1 ? PRF_ENTRIES : 2)-1:0];
          if (lane_i[q].v && lane_i[q].do_falloc &&
              (lane_i[q].hart == lane_i[p].hart))
            pub_ck_faval_o[p] |= FPN'(1) <<
                     lane_i[q].fprd[$clog2(FPN > 1 ? FPN : 2)-1:0];
        end
        pub_ck_v_o[p]      = 1'b1;
        pub_ck_slot_o[p]   = lane_i[p].ckpt_slot;
        pub_ck_h_o[p]      = lane_i[p].hart;
        pub_ck_map_o[p]    = wm[lane_i[p].hart];
        pub_ck_fmap_o[p]   = fwm[lane_i[p].hart];
      end
    end
  end

endmodule
