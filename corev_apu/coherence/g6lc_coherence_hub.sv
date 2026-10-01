// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.2 coherent multi-core hub — N AXI masters → 1 AXI toward L2/memory
// + write-invalidate + LR/SC cluster tracking.
//
// Aggressive contention optimisations (vs single-serial ARB):
//   1. Split AR || AW channels — read and write address grants concurrent
//   2. Multi-outstanding via OT scoreboard: mem-side id = slot, restore
//      original core AXI id on R/B (never clobber L1 tid bits — I$ uses
//      ICACHE_RDTXID = 1<<(MEM_TID_WIDTH-1) which collides with "encode
//      core in upper AXI id bits")
//   3. Independent RR + starve counters per channel
//   4. Snoop filter guided inv (owners only)
//   5. Inv coalesce + per-core FIFOs (g6lc_inval_bus)
//   6. Invalidation retention beyond AXI credits remains a separate obligation
//   7. Global LR/SC tracker — kill remote reservations on store/AMO
//   8. NC (non-cacheable) skips SF/inv entirely
//   9. NR_CORES==1 → pure AXI identity

module g6lc_coherence_hub
  import g6lc_coherence_pkg::*;
  import config_pkg::*;
#(
    parameter int unsigned NR_CORES             = 1,
    parameter bit          SNOOP_FILTER_EN      = 1'b1,
    parameter int unsigned SNOOP_FILTER_ENTRIES = COH_DEFAULT_SF_ENTRIES,
    parameter int unsigned INVAL_DEPTH          = COH_DEFAULT_INVAL_DEPTH,
    parameter int unsigned LINE_BYTES           = COH_DEFAULT_LINE_BYTES,
    parameter int unsigned AXI_STARVE_LIMIT     = 16,
    parameter int unsigned MAX_OUTSTANDING      = 4,  // shared AR/AW slots
    parameter coh_policy_t POLICY               = COH_FILTERED,
    // Withhold the writer's B response until its invalidation obligation has
    // been delivered to every target core (bus pop) plus INV_APPLY_LATENCY
    // margin cycles for the target L1 to apply it. 0 selects the
    // ack-before-invalidation compatibility mode.
    parameter bit          ACK_AFTER_INVAL      = 1'b1,
    // Extra settle cycles between bus delivery (pop edge E) and B forwarding.
    // The WT L1 applies a popped invalidation during E+1 (array write at the
    // E+1 edge), so the minimum safe B presentation is E+2 -- latency 0. The
    // default of 1 adds one margin cycle.
    parameter int unsigned INV_APPLY_LATENCY    = 1,
    parameter int unsigned AXI_ADDR_WIDTH       = 64,
    parameter int unsigned AXI_DATA_WIDTH       = 64,
    parameter int unsigned AXI_ID_WIDTH         = 4,
    parameter int unsigned AXI_USER_WIDTH       = 1,
    parameter type         axi_req_t            = logic,
    parameter type         axi_resp_t           = logic
) (
    input  logic     clk_i,
    input  logic     rst_ni,
    input  axi_req_t  [NR_CORES-1:0] core_req_i,
    output axi_resp_t [NR_CORES-1:0] core_resp_o,
    output axi_req_t  mem_req_o,
    input  axi_resp_t mem_resp_i,
    output coh_inval_t [NR_CORES-1:0] inv_core_o,
    input  logic       [NR_CORES-1:0] inv_core_ready_i,
    // Optional LR/SC sideband (tie 0 if unused)
    input  logic                       lr_valid_i,
    input  logic [AXI_ADDR_WIDTH-1:0]  lr_addr_i,
    input  logic [$clog2(NR_CORES > 1 ? NR_CORES : 2)-1:0] lr_core_i,
    output logic                       coh_inv_fire_o,
    output logic                       coh_sf_hit_o,
    output logic                       coh_sf_overapprox_o,
    output logic                       coh_arb_starve_o,
    output logic                       coh_split_conflict_o, // W-data vs AW owner mismatch
    // SC-shaped store with no reservation recorded here (see g6lc_lr_sc_tracker).
    output logic                       coh_sc_noresv_o,
    output logic                       coh_lr_kill_o,
    // T9c/M1c hold-cycle level: any core offers an AW while a live AW slot
    // of the SAME core already holds that line — the R2 same-line/different-
    // id hold the L2 will charge counts as same-core serialization here
    // (the L2 only sees the hub's slot ids). The TB counts it as
    // hub_aw_sc_collide; leave unconnected elsewhere.
    output logic                       hub_aw_sc_collide_o,
    // T9e/M1d hold-cycle level: any core offers an AR that is ineligible
    // because a same-line AW is pending at a port or live in an AW slot —
    // the hub-side read-behind-write hold (ar_wr_line_live). The TB counts
    // it as hub_ar_hold; leave unconnected elsewhere.
    output logic                       hub_ar_wr_hold_o,
    // T10c/N4 hold-cycle levels: an AW actually held at a core port
    // (aw_valid && !aw_ready), split by blocker. _slot: the shared AR/AW
    // slot table or the AW free-slot pick is exhausted (slot_used/AR
    // pre-emption); _other: W-data in flight, inv-retention admission,
    // signature gating, mem-side !aw_ready, or an RR loss. The same-line
    // collide above never gates aw_grant — it is observation only.
    output logic                       hub_aw_hold_slot_o,
    output logic                       hub_aw_hold_other_o
);

  localparam bit OOO_SF = (POLICY == COH_OOO) && SNOOP_FILTER_EN;
  localparam int unsigned NC     = (NR_CORES < 1) ? 1 : NR_CORES;
  localparam int unsigned CID_W  = (NC <= 1) ? 1 : $clog2(NC);
  localparam int unsigned ST_W   = (AXI_STARVE_LIMIT <= 1) ? 1 : $clog2(AXI_STARVE_LIMIT + 1);
  // Outstanding table slots: mem-side AXI id is the slot index. Cap by both
  // MAX_OUTSTANDING and the id space so the slot always fits in AXI_ID_WIDTH.
  localparam int unsigned OT_ID_CAP = (AXI_ID_WIDTH >= 31) ? 32'd32 : (32'd1 << AXI_ID_WIDTH);
  localparam int unsigned OT_MAX =
      (MAX_OUTSTANDING < 1) ? 1 :
      (MAX_OUTSTANDING > OT_ID_CAP) ? OT_ID_CAP : MAX_OUTSTANDING;
  localparam int unsigned OT_W   = (OT_MAX <= 1) ? 1 : $clog2(OT_MAX);
  localparam int unsigned OT_CNT_W = (OT_MAX <= 1) ? 1 : $clog2(OT_MAX + 1);

  if (NC > 1 && OOO_SF && OT_MAX < 2) begin : gen_bad_signature_credits
    $error("OoO coherence signatures require at least two transaction credits");
    //pragma translate_off
`ifndef SYNTHESIS
    initial $fatal(1, "OoO coherence signatures require at least two transaction credits");
`endif
    //pragma translate_on
  end

  if (INV_APPLY_LATENCY > 3) begin : gen_bad_inv_latency
    $error("INV_APPLY_LATENCY must be in 0..3");
    //pragma translate_off
`ifndef SYNTHESIS
    initial $fatal(1, "INV_APPLY_LATENCY must be in 0..3");
`endif
    //pragma translate_on
  end

  if (NC <= 1) begin : gen_identity
    assign mem_req_o            = core_req_i[0];
    assign core_resp_o[0]       = mem_resp_i;
    assign inv_core_o           = '{default: '0};
    assign coh_inv_fire_o       = 1'b0;
    assign coh_sf_hit_o         = 1'b0;
    assign coh_sf_overapprox_o  = 1'b0;
    assign coh_arb_starve_o     = 1'b0;
    assign coh_split_conflict_o = 1'b0;
    assign coh_sc_noresv_o      = 1'b0;
    assign coh_lr_kill_o        = 1'b0;
    assign hub_aw_sc_collide_o  = 1'b0;
    assign hub_ar_wr_hold_o     = 1'b0;
    assign hub_aw_hold_slot_o   = 1'b0;
    assign hub_aw_hold_other_o  = 1'b0;
  end else begin : gen_cluster

    // ================================================================
    // Split-channel RR + starve (AR and AW independent)
    // ================================================================
    logic [CID_W-1:0] aw_rr_q, aw_rr_d, ar_rr_q, ar_rr_d;
    logic [ST_W-1:0]  aw_starve_q[NC], aw_starve_d[NC];
    logic [ST_W-1:0]  ar_starve_q[NC], ar_starve_d[NC];
    logic [NC-1:0]    aw_req, ar_req;
    logic [CID_W-1:0] aw_winner, ar_winner;
    logic             aw_starve_force, ar_starve_force;
    logic aw_hold_q, ar_hold_q;
    logic [CID_W-1:0] aw_hold_owner_q, ar_hold_owner_q;
    logic [OT_W-1:0] aw_hold_slot_q, ar_hold_slot_q;
    logic sig_initialized, sig_start, sig_pending_q, sig_done_q, sig_result_valid;
    logic sig_alloc_ready, coh_block_ar;
    logic [CID_W-1:0] sig_owner_q;
    logic [NC-1:0] sig_present, sig_present_q;

    // Every AR is re-tagged with its slot index toward memory, so two reads
    // from one core with the same original id become distinct ids downstream
    // and the L2 may legally answer the younger one first (hit under miss).
    // AXI still owes the core same-id R order, so a core's AR is not eligible
    // while an older AR slot of the same (core, original id) is live.
    logic [NC-1:0] ar_same_id_live;
    // Same-line RAW closure (HUB_STALE_REFILL_PUBLICATION): a fill whose AR is
    // forwarded to memory while a same-line write is still pending at the port
    // or live in an AW slot can return pre-write data. The write's
    // invalidation was already delivered (or will be consumed before the fill
    // lands), so nothing kills the stale copy afterwards. An AR is therefore
    // ineligible until no AW input request and no live AW slot carries the
    // same line -- the slot only frees after B is forwarded, i.e. after the
    // write's data is in memory and its invalidation was applied everywhere.
    logic [NC-1:0] ar_wr_line_live;
    for (genvar c = 0; c < NC; c++) begin : gen_req
      assign aw_req[c] = core_req_i[c].aw_valid;
      assign ar_req[c] = core_req_i[c].ar_valid && !ar_same_id_live[c] &&
                         !ar_wr_line_live[c];
    end

    function automatic logic [CID_W-1:0] pick_rr(
        input logic [NC-1:0] reqs,
        input logic [CID_W-1:0] start
    );
      logic [CID_W-1:0] sel;
      logic found;
      sel   = start;
      found = 1'b0;
      for (int unsigned k = 0; k < NC; k++) begin
        automatic logic [CID_W-1:0] cand;
        cand = CID_W'((int'(start) + k) % NC);
        if (reqs[cand] && !found) begin
          sel   = cand;
          found = 1'b1;
        end
      end
      return sel;
    endfunction

    //  The starve override picks ROUND-ROBIN among starved cores, not "last one
    //  the loop looked at".
    //
    //  The previous form assigned `winner = c` inside the scan, so the
    //  HIGHEST-INDEXED starved core won every time. That is harmless while the
    //  override never engages, and it does not engage at 2 or 4 cores even with
    //  memory accepting one request in four. At EIGHT cores with the same memory it
    //  engages hard, and the consequence is not a mild bias: measured
    //  1,1,1,100,100,99,99,99 grants over 2000 cycles -- a hundredfold disparity --
    //  and at one-in-eight acceptance a core is never granted at all. The mechanism
    //  meant to rescue a starved core was instead the thing starving it, because a
    //  core that wins re-qualifies immediately and keeps winning the tie.
    //
    //  Reusing pick_rr over the starved subset keeps the rotation the fair path
    //  already has, so a forced grant advances the pointer's intent instead of
    //  fighting it. No new state: the mask is combinational over existing counters.
    logic [NC-1:0] aw_starved_req, ar_starved_req;
    for (genvar c = 0; c < NC; c++) begin : gen_starved_mask
      assign aw_starved_req[c] = (AXI_STARVE_LIMIT != 0) && aw_req[c] &&
                                 (aw_starve_q[c] >= AXI_STARVE_LIMIT[ST_W-1:0]);
      assign ar_starved_req[c] = (AXI_STARVE_LIMIT != 0) && ar_req[c] &&
                                 (ar_starve_q[c] >= AXI_STARVE_LIMIT[ST_W-1:0]);
    end

    always_comb begin
      aw_winner       = pick_rr(aw_req, aw_rr_q);
      ar_winner       = pick_rr(ar_req, ar_rr_q);
      aw_starve_force = 1'b0;
      ar_starve_force = 1'b0;
      if (|aw_starved_req) begin
        aw_winner       = pick_rr(aw_starved_req, aw_rr_q);
        aw_starve_force = 1'b1;
      end
      if (|ar_starved_req) begin
        ar_winner       = pick_rr(ar_starved_req, ar_rr_q);
        ar_starve_force = 1'b1;
      end
      if (aw_hold_q) begin
        aw_winner = aw_hold_owner_q;
        aw_starve_force = 1'b0;
      end
      if (ar_hold_q) begin
        ar_winner = ar_hold_owner_q;
        ar_starve_force = 1'b0;
      end
      if (OOO_SF && sig_pending_q) begin
        aw_winner = sig_owner_q;
        aw_starve_force = 1'b0;
      end
    end

    assign coh_arb_starve_o = aw_starve_force | ar_starve_force;

    // Outstanding scoreboard: mem-side AXI id = slot index; original core id
    // restored on R/B so L1 tid bits (e.g. ICACHE_RDTXID) are never clobbered.
    // expect_r: AXI ATOP with bit5 set (AtomicLoad / Swap / Compare) returns old
    // data on R with the AW id. axi_riscv_amos injects that R *after* B, so we
    // must not free aw_ot on B alone — otherwise R is safety-drained and the
    // core never sees amoswap/amocas completion (OpenSBI boot-lottery hang).
    typedef struct packed {
      logic                      valid;
      logic                      expect_r;
      logic                      b_done;
      logic [CID_W-1:0]          core;
      logic [AXI_ID_WIDTH-1:0]   orig_id;
      // b_held: the mem-side B was consumed but is withheld from the core
      // until the invalidation has been applied.
      logic                                b_held;
      logic [1:0]                          b_resp;
      logic [AXI_USER_WIDTH-1:0]           b_user;
      // r_held: the mem-side ATOP R beat was consumed but is withheld from
      // the core until the invalidation has been applied (b_held analogue).
      // Parking is mandatory, not optional: withholding the beat at the port
      // (r_ready=0) stalls the single shared R channel, and the same-line
      // fill whose completion inv_fill_hold waits on may be queued behind it
      // -- ATOP R waits on delivery, delivery waits on the fill, the fill's
      // R waits on the ATOP R. Deadlock (observed: amocas second-op hang,
      // OpenSBI boot-lottery amoswap stall).
      logic                                r_held;
      logic                                r_last;
      logic [AXI_DATA_WIDTH-1:0]           r_data;
      logic [1:0]                          r_resp;
      logic [AXI_USER_WIDTH-1:0]           r_user;
      // Line tag of the request, registered at admission. AR slots use it to
      // hold an invalidation delivery until the fill lands; AW slots use it
      // to keep same-line ARs ineligible until the write has fully completed
      // (stale-refill publication closure).
      logic [55:0]                         line_addr;
    } ot_entry_t;

    // ACK-after-invalidation bookkeeping (AW slots only). Kept in a separate
    // array because it is written by the invalidation process, which reads the
    // bus's combinational accept path -- reading that path in the process that
    // produces aw_fire would close a combinational loop.
    //   inv_owed: an obligation exists that the bus has not accepted yet (it
    //     lives in inv_pend); the slot must not ack until it is stamped.
    //   inv_wait: cores whose delivery pop is still outstanding.
    //   inv_need: per-core enqueue sequence number inv_deq_seq must reach.
    //   inv_settle: saturating count of cycles since the last wait bit fell.
    typedef struct packed {
      logic                             inv_owed;
      logic [NC-1:0]                    inv_wait;
      logic [NC-1:0][COH_INV_SEQ_W-1:0] inv_need;
      logic [1:0]                       inv_settle;
    } inv_ot_t;

    ot_entry_t ar_ot_q[OT_MAX], ar_ot_d[OT_MAX];
    ot_entry_t aw_ot_q[OT_MAX], aw_ot_d[OT_MAX];
    inv_ot_t   inv_ot_q[OT_MAX], inv_ot_d[OT_MAX];
    logic [OT_CNT_W-1:0] ar_ot_cnt_q, ar_ot_cnt_d, aw_ot_cnt_q, aw_ot_cnt_d;
    logic ar_ot_full, aw_ot_full;
    logic [OT_W-1:0] ar_free_slot, aw_free_slot;
    logic            ar_have_free, aw_have_free;

    // AR and AW share the mem-side ID/slot space: a slot may be AR *or* AW,
    // never both (ATOP load returns R with the AW id; concurrent AR with the
    // same id would be un-demuxable).
    logic [OT_MAX-1:0] slot_used;
    for (genvar s = 0; s < OT_MAX; s++) begin : gen_slot_used
      assign slot_used[s] = ar_ot_q[s].valid | aw_ot_q[s].valid |
          (ar_hold_q && ar_hold_slot_q == OT_W'(s)) |
          (aw_hold_q && aw_hold_slot_q == OT_W'(s));
    end
    assign ar_ot_full = &slot_used;
    assign aw_ot_full = &slot_used;

    // Per-core invalidation delivery hold: while core c still has a same-line
    // fill outstanding -- an AR that beat the write to the memory port and may
    // legally return pre-write data -- the head of c's invalidation queue is
    // neither presented nor popped, so the invalidation lands after the fill
    // and kills the stale copy. A held AR already at the memory port
    // (ar_hold) counts as an outstanding fill for the same reason.
    logic [NC-1:0]   inv_fill_hold;
    coh_inval_t [NC-1:0] inv_bus_o;
    logic [NC-1:0]   inv_bus_ready;

    always_comb begin
      ar_same_id_live = '0;
      ar_wr_line_live = '0;
      inv_fill_hold   = '0;
      for (int unsigned c = 0; c < NC; c++) begin
        automatic logic [55:0] ar_line;
        ar_line = coh_line_tag(core_req_i[c].ar.addr, LINE_BYTES);
        for (int unsigned c2 = 0; c2 < NC; c2++) begin
          if (core_req_i[c2].aw_valid &&
              coh_line_tag(core_req_i[c2].aw.addr, LINE_BYTES) == ar_line)
            ar_wr_line_live[c] = 1'b1;
        end
        for (int unsigned s = 0; s < OT_MAX; s++) begin
          if (ar_ot_q[s].valid && ar_ot_q[s].core == CID_W'(c) &&
              ar_ot_q[s].orig_id == core_req_i[c].ar.id)
            ar_same_id_live[c] = 1'b1;
          if (aw_ot_q[s].valid && aw_ot_q[s].line_addr == ar_line)
            ar_wr_line_live[c] = 1'b1;
          if (ar_ot_q[s].valid && ar_ot_q[s].core == CID_W'(c) &&
              inv_bus_o[c].valid &&
              ar_ot_q[s].line_addr == inv_bus_o[c].line_addr)
            inv_fill_hold[c] = 1'b1;
        end
        if (ar_hold_q && ar_hold_owner_q == CID_W'(c) &&
            inv_bus_o[c].valid && ar_line == inv_bus_o[c].line_addr)
          inv_fill_hold[c] = 1'b1;
      end
    end

    // M1c: an offered AW colliding on line with a live AW slot of the same
    // core — the R2 serialization the L2 will charge is same-core. Level
    // counts hold cycles; nc=1 folds to the gen_identity tie-off.
    always_comb begin
      hub_aw_sc_collide_o = 1'b0;
      for (int unsigned c = 0; c < NC; c++) begin
        if (core_req_i[c].aw_valid) begin
          for (int unsigned s = 0; s < OT_MAX; s++) begin
            if (aw_ot_q[s].valid && aw_ot_q[s].core == CID_W'(c) &&
                aw_ot_q[s].line_addr ==
                    coh_line_tag(core_req_i[c].aw.addr, LINE_BYTES))
              hub_aw_sc_collide_o = 1'b1;
          end
        end
      end
    end

    // T10c/N4: an AW actually held at a core port (aw_valid && !aw_ready),
    // split by blocker — slot table exhausted vs everything else. The
    // same-line collide above is *not* in aw_grant, so a collide alone
    // never produces a hold.
    always_comb begin
      hub_aw_hold_slot_o  = 1'b0;
      hub_aw_hold_other_o = 1'b0;
      for (int unsigned c = 0; c < NC; c++) begin
        if (core_req_i[c].aw_valid && !core_resp_o[c].aw_ready) begin
          if (aw_ot_full || !aw_have_free) hub_aw_hold_slot_o  = 1'b1;
          else                             hub_aw_hold_other_o = 1'b1;
        end
      end
    end

    // T9e/M1d: an offered AR held ineligible by the same-line AW rule —
    // the hub-side read-behind-write cost. Level counts hold cycles;
    // nc=1 folds to the gen_identity tie-off.
    always_comb begin
      hub_ar_wr_hold_o = 1'b0;
      for (int unsigned c = 0; c < NC; c++)
        if (core_req_i[c].ar_valid && ar_wr_line_live[c])
          hub_ar_wr_hold_o = 1'b1;
    end

    // The hold suppresses both pop and presentation: a suppressed head is not
    // visible to the core at all, so no ready edge can be mistaken for a
    // delivery while the fill it must outlive is still in flight.
    for (genvar c = 0; c < NC; c++) begin : gen_inv_hold
      assign inv_core_o[c]       = '{valid:   inv_bus_o[c].valid && !inv_fill_hold[c],
                                     all_ways: inv_bus_o[c].all_ways,
                                     dcache:   inv_bus_o[c].dcache,
                                     icache:   inv_bus_o[c].icache,
                                     line_addr: inv_bus_o[c].line_addr};
      assign inv_bus_ready[c]    = inv_core_ready_i[c] && !inv_fill_hold[c];
    end

    always_comb begin
      ar_have_free = 1'b0;
      aw_have_free = 1'b0;
      ar_free_slot = '0;
      aw_free_slot = '0;
      for (int unsigned s = 0; s < OT_MAX; s++) begin
        if (!slot_used[s] && !ar_have_free) begin
          ar_have_free = 1'b1;
          ar_free_slot = OT_W'(s);
        end
        if (!slot_used[s] && !aw_have_free) begin
          aw_have_free = 1'b1;
          aw_free_slot = OT_W'(s);
        end
      end
      // Prefer distinct free slots when a new AR actually competes
      // (combinational tie-break: AW takes next free after AR's choice)
      if (ar_have_free && aw_have_free && |ar_req && !ar_hold_q && !coh_block_ar &&
          (ar_free_slot == aw_free_slot)) begin
        aw_have_free = 1'b0;
        for (int unsigned s = 0; s < OT_MAX; s++) begin
          if (!slot_used[s] && OT_W'(s) != ar_free_slot && !aw_have_free) begin
            aw_have_free = 1'b1;
            aw_free_slot = OT_W'(s);
          end
        end
      end
      if (ar_hold_q) begin
        ar_have_free = 1'b1;
        ar_free_slot = ar_hold_slot_q;
      end
      if (aw_hold_q) begin
        aw_have_free = 1'b1;
        aw_free_slot = aw_hold_slot_q;
      end
    end

    // Write data owner follows last accepted AW (AXI W has no id)
    logic [CID_W-1:0] w_owner_q, w_owner_d;
    logic             w_busy_q, w_busy_d;
    // Slot of the in-flight W-data owner (for optional debug); B uses scoreboard.
    logic [OT_W-1:0]  w_slot_q, w_slot_d;

    // Inv ready (from bus). Still never used to gate AW: admission consults the
    // registered retention occupancy below instead, which keeps the obligation
    // lossless without creating an AW<->inv combinational loop.
    logic inv_ready;
    // Per-core delivery sequences exported by the invalidation bus.
    logic [NC-1:0][COH_INV_SEQ_W-1:0] inv_enq_seq, inv_deq_seq;

    // Retained invalidation obligation for an already-accepted write.
    coh_inval_t    inv_pend_q, inv_pend_d;
    logic [NC-1:0] inv_pend_tgt_q, inv_pend_tgt_d;
    logic          inv_pend_valid_q, inv_pend_valid_d;
    // AW slot that owns the retained obligation (valid only when the captured
    // obligation was write-owned; guarded by the slot's inv_owed at stamp).
    logic [OT_W-1:0] inv_pend_slot_q, inv_pend_slot_d;

    // A write-owned obligation is not yet safe to ack even before it is
    // stamped: between AW acceptance and bus acceptance the slot carries
    // inv_owed, which keeps applied() false.
    function automatic logic slot_applied(input inv_ot_t e);
      return !ACK_AFTER_INVAL ||
             (!e.inv_owed && (e.inv_wait == '0) &&
              (e.inv_settle >= 2'(INV_APPLY_LATENCY)));
    endfunction

    logic [NC-1:0]   b_offer_locked_q;
    logic [OT_W-1:0] b_offer_slot_q [NC];
    logic [OT_W-1:0] b_offer_slot [NC];
    logic [OT_MAX-1:0] b_predecessors_q [OT_MAX], b_predecessors_d [OT_MAX];
    logic [OT_MAX-1:0] b_completed;

    // Lowest-index held-B slot per core that may be presented this cycle.
    logic [NC-1:0]   held_found;
    logic [OT_W-1:0] held_slot [NC];

    always_comb begin
      held_found = '0;
      for (int unsigned c = 0; c < NC; c++) held_slot[c] = '0;
      for (int unsigned s = 0; s < OT_MAX; s++) begin
        if (aw_ot_q[s].valid && aw_ot_q[s].b_held &&
            (b_predecessors_q[s] == '0) &&
            slot_applied(inv_ot_q[s]) && !held_found[aw_ot_q[s].core] &&
            (!b_offer_locked_q[aw_ot_q[s].core] ||
             b_offer_slot_q[aw_ot_q[s].core] == OT_W'(s))) begin
          held_found[aw_ot_q[s].core] = 1'b1;
          held_slot[aw_ot_q[s].core]  = OT_W'(s);
        end
      end
    end

    // Lowest-index parked-R slot per core that may be replayed this cycle.
    // Unlike held-B there is no predecessors list: ATOP R beats carry the AW
    // slot id and AXI imposes no cross-id ordering on R.
    logic [NC-1:0]   r_held_found;
    logic [OT_W-1:0] r_held_slot [NC];

    always_comb begin
      r_held_found = '0;
      for (int unsigned c = 0; c < NC; c++) r_held_slot[c] = '0;
      for (int unsigned s = 0; s < OT_MAX; s++) begin
        if (aw_ot_q[s].valid && aw_ot_q[s].r_held &&
            slot_applied(inv_ot_q[s]) && !r_held_found[aw_ot_q[s].core]) begin
          r_held_found[aw_ot_q[s].core] = 1'b1;
          r_held_slot[aw_ot_q[s].core]  = OT_W'(s);
        end
      end
    end

    // Combinational grant eligibility
    logic aw_grant, ar_grant;
    logic aw_fire, ar_fire, w_fire, b_fire, r_fire;
    logic aw_may_invalidate;
    assign aw_may_invalidate = core_req_i[aw_winner].aw.cache[1] ||
        (|core_req_i[aw_winner].aw.atop) || core_req_i[aw_winner].aw.lock;
    assign coh_block_ar = OOO_SF &&
        (sig_pending_q || (!w_busy_q && |aw_req && !ar_hold_q));
    assign sig_start = OOO_SF && sig_initialized && !sig_pending_q && !ar_hold_q &&
        !w_busy_q && !inv_pend_valid_q && |aw_req && !aw_ot_full;

    always_comb begin
      logic [OT_W-1:0] bs, rs;
      logic [CID_W-1:0] bc, rc;
      logic b_id_ok, r_id_ok;
      // Defaults
      bs = '0;
      rs = '0;
      bc = '0;
      rc = '0;
      b_id_ok = 1'b0;
      r_id_ok = 1'b0;
      mem_req_o   = '0;
      aw_fire     = 1'b0;
      ar_fire     = 1'b0;
      w_fire      = 1'b0;
      b_fire      = 1'b0;
      b_completed = '0;
      r_fire      = 1'b0;
      aw_rr_d     = aw_rr_q;
      ar_rr_d     = ar_rr_q;
      ar_ot_cnt_d = ar_ot_cnt_q;
      aw_ot_cnt_d = aw_ot_cnt_q;
      w_owner_d   = w_owner_q;
      w_busy_d    = w_busy_q;
      w_slot_d    = w_slot_q;
      for (int unsigned s = 0; s < OT_MAX; s++) begin
        ar_ot_d[s] = ar_ot_q[s];
        aw_ot_d[s] = aw_ot_q[s];
      end
      for (int unsigned c = 0; c < NC; c++) begin
        aw_starve_d[c] = aw_starve_q[c];
        ar_starve_d[c] = ar_starve_q[c];
        b_offer_slot[c] = '0;
        core_resp_o[c] = '0;
        core_resp_o[c].aw_ready = 1'b0;
        core_resp_o[c].w_ready  = 1'b0;
        core_resp_o[c].ar_ready = 1'b0;
        core_resp_o[c].b_valid  = 1'b0;
        core_resp_o[c].r_valid  = 1'b0;
      end

      // ---- AW path (OT-limited; inv is best-effort side path) ----
      // Drive mem aw_valid from request availability alone — do NOT gate on
      // mem aw_ready (downstream L2 only asserts ready when valid is high;
      // gating valid on ready is a combinational deadlock).
      // Hold new AW while write data for previous AW still in flight (W has no id).
      // A write that will require an invalidation may only be admitted when the
      // retention slot is free, so its obligation cannot be dropped. This reads
      // only registered occupancy and the incoming cache attribute, never
      // inv_ready or aw_fire, so admission stays loop-free.
      aw_grant = (aw_hold_q || (|aw_req && !aw_ot_full && aw_have_free && !w_busy_q &&
                               !(aw_may_invalidate && inv_pend_valid_q))) &&
                 (!OOO_SF || (sig_pending_q && (sig_done_q || sig_result_valid)));

      if (aw_grant) begin
        mem_req_o.aw       = core_req_i[aw_winner].aw;
        mem_req_o.aw.id    = AXI_ID_WIDTH'(aw_free_slot);
        mem_req_o.aw_valid = 1'b1;
      end
      // Fire only on valid&&ready handshake
      if (aw_grant && mem_resp_i.aw_ready) begin
        core_resp_o[aw_winner].aw_ready = 1'b1;
        aw_fire   = 1'b1;
        aw_rr_d   = CID_W'((int'(aw_winner) + 1) % NC);
        aw_ot_cnt_d = aw_ot_cnt_q + 1'b1;
        aw_ot_d[aw_free_slot].valid    = 1'b1;
        // AXI ATOP[5]=1 ⇒ R beat with AW id (load/swap/compare)
        aw_ot_d[aw_free_slot].expect_r = core_req_i[aw_winner].aw.atop[5];
        aw_ot_d[aw_free_slot].b_done   = 1'b0;
        aw_ot_d[aw_free_slot].core     = aw_winner;
        aw_ot_d[aw_free_slot].orig_id  = core_req_i[aw_winner].aw.id;
        aw_ot_d[aw_free_slot].line_addr =
            coh_line_tag(core_req_i[aw_winner].aw.addr, LINE_BYTES);
        aw_ot_d[aw_free_slot].b_held     = 1'b0;
        aw_ot_d[aw_free_slot].r_held     = 1'b0;
        w_owner_d = aw_winner;
        w_slot_d  = aw_free_slot;
        w_busy_d  = 1'b1;
      end

      // ---- AR path (independent of AW) — same valid/ready split ----
      ar_grant = ar_hold_q || (|ar_req && !ar_ot_full && ar_have_free &&
                              (!OOO_SF || (sig_initialized && sig_alloc_ready && !coh_block_ar)));
      if (ar_grant) begin
        mem_req_o.ar       = core_req_i[ar_winner].ar;
        // Mem-side id = OT slot (AR/AW share slot space; see slot_used above).
        mem_req_o.ar.id    = AXI_ID_WIDTH'(ar_free_slot);
        mem_req_o.ar_valid = 1'b1;
      end
      if (ar_grant && mem_resp_i.ar_ready) begin
        core_resp_o[ar_winner].ar_ready = 1'b1;
        ar_fire = 1'b1;
        ar_rr_d = CID_W'((int'(ar_winner) + 1) % NC);
        ar_ot_cnt_d = ar_ot_cnt_q + 1'b1;
        ar_ot_d[ar_free_slot].valid   = 1'b1;
        ar_ot_d[ar_free_slot].core    = ar_winner;
        ar_ot_d[ar_free_slot].orig_id = core_req_i[ar_winner].ar.id;
        ar_ot_d[ar_free_slot].line_addr =
            coh_line_tag(core_req_i[ar_winner].ar.addr, LINE_BYTES);
      end

      // ---- W data follows w_owner ----
      if (w_busy_q && core_req_i[w_owner_q].w_valid) begin
        mem_req_o.w       = core_req_i[w_owner_q].w;
        mem_req_o.w_valid = 1'b1;
        core_resp_o[w_owner_q].w_ready = mem_resp_i.w_ready;
        if (mem_resp_i.w_ready) begin
          w_fire = 1'b1;
          if (core_req_i[w_owner_q].w.last) w_busy_d = 1'b0;
        end
      end

      // ---- Held-B presentation ----
      // A B consumed while its invalidation was still in flight is offered to
      // the core on the first cycle the slot reports applied(). The AXI
      // response/user captured at consumption are replayed verbatim; only the
      // original core id is restored, exactly like the passthrough below.
      for (int unsigned c = 0; c < NC; c++) begin
        if (held_found[c]) begin
          b_offer_slot[c] = held_slot[c];
          core_resp_o[c].b_valid = 1'b1;
          core_resp_o[c].b.id    = aw_ot_q[held_slot[c]].orig_id;
          core_resp_o[c].b.resp  = aw_ot_q[held_slot[c]].b_resp;
          core_resp_o[c].b.user  = aw_ot_q[held_slot[c]].b_user;
          if (core_req_i[c].b_ready) begin
            b_fire = 1'b1;
            b_completed[held_slot[c]] = 1'b1;
            aw_ot_d[held_slot[c]].b_held = 1'b0;
            if (aw_ot_q[held_slot[c]].expect_r) begin
              // Keep slot until ATOP R is forwarded (amos injects R after B)
              aw_ot_d[held_slot[c]].b_done = 1'b1;
            end else begin
              aw_ot_d[held_slot[c]].valid = 1'b0;
              if (aw_ot_cnt_d != '0) aw_ot_cnt_d = aw_ot_cnt_d - 1'b1;
            end
          end
        end
      end

      // ---- B response demux by OT slot id; restore original core id ----
      if (mem_resp_i.b_valid) begin
        // Compare full id against OT_MAX (do not truncate OT_MAX to OT_W bits —
        // when OT_MAX is a power of two that truncates to 0).
        b_id_ok = ({1'b0, mem_resp_i.b.id} < (AXI_ID_WIDTH + 1)'(OT_MAX));
        bs      = OT_W'(mem_resp_i.b.id);
        if (b_id_ok && aw_ot_q[bs].valid) begin
          bc = aw_ot_q[bs].core;
          if ((b_predecessors_q[bs] == '0) &&
              slot_applied(inv_ot_q[bs]) && !held_found[bc] &&
              (!b_offer_locked_q[bc] || b_offer_slot_q[bc] == bs)) begin
            // Fast path: obligation already delivered and settled (or the
            // write carried none) -- forward B with no added latency.
            b_offer_slot[bc] = bs;
            core_resp_o[bc].b_valid = 1'b1;
            core_resp_o[bc].b       = mem_resp_i.b;
            core_resp_o[bc].b.id    = aw_ot_q[bs].orig_id;
            mem_req_o.b_ready = core_req_i[bc].b_ready;
            if (core_req_i[bc].b_ready) begin
              b_fire = 1'b1;
              b_completed[bs] = 1'b1;
              if (aw_ot_q[bs].expect_r) begin
                // Keep slot until ATOP R is forwarded (amos injects R after B)
                aw_ot_d[bs].b_done = 1'b1;
              end else begin
                aw_ot_d[bs].valid = 1'b0;
                if (aw_ot_cnt_d != '0) aw_ot_cnt_d = aw_ot_cnt_d - 1'b1;
              end
            end
          end else begin
            // Park the response: consume it from memory (resp/user captured)
            // and replay it once the invalidation has been applied.
            mem_req_o.b_ready  = 1'b1;
            aw_ot_d[bs].b_held = 1'b1;
            aw_ot_d[bs].b_resp = mem_resp_i.b.resp;
            aw_ot_d[bs].b_user = mem_resp_i.b.user;
          end
        end else begin
          // Safety: free the mem response so a bad id cannot hang the interconnect
          mem_req_o.b_ready = 1'b1;
        end
      end

      // ---- Held-R presentation ----
      // Same replay contract as held-B: the ATOP R beat consumed while its
      // invalidation was still in flight is offered on the first cycle the
      // slot reports applied(); the payload is replayed verbatim with the
      // original core id restored. Placed after the B demux so a same-cycle
      // B handshake's b_done update is visible when the slot is freed.
      // A replayed beat takes the port over a fresh R to the same core —
      // otherwise a second hart's fill stream could starve it indefinitely
      // while the ATOP's hart waits for completion.
      for (int unsigned c = 0; c < NC; c++) begin
        if (r_held_found[c]) begin
          core_resp_o[c].r_valid = 1'b1;
          core_resp_o[c].r.data  = aw_ot_q[r_held_slot[c]].r_data;
          core_resp_o[c].r.resp  = aw_ot_q[r_held_slot[c]].r_resp;
          core_resp_o[c].r.last  = aw_ot_q[r_held_slot[c]].r_last;
          core_resp_o[c].r.user  = aw_ot_q[r_held_slot[c]].r_user;
          core_resp_o[c].r.id    = aw_ot_q[r_held_slot[c]].orig_id;
          if (core_req_i[c].r_ready) begin
            aw_ot_d[r_held_slot[c]].r_held = 1'b0;
            if (aw_ot_q[r_held_slot[c]].r_last) begin
              r_fire = 1'b1;
              aw_ot_d[r_held_slot[c]].expect_r = 1'b0;
              if (aw_ot_d[r_held_slot[c]].b_done) begin
                aw_ot_d[r_held_slot[c]].valid = 1'b0;
                if (aw_ot_cnt_d != '0) aw_ot_cnt_d = aw_ot_cnt_d - 1'b1;
              end
            end
          end
        end
      end

      // ---- R response demux by OT slot id; restore original core id ----
      // Normal reads: slot in ar_ot. AXI ATOP load/swap/compare returns old
      // data on R with the *AW* id — demux via aw_ot and free the slot here
      // (B may already have completed; see expect_r above).
      if (mem_resp_i.r_valid) begin
        r_id_ok = ({1'b0, mem_resp_i.r.id} < (AXI_ID_WIDTH + 1)'(OT_MAX));
        rs      = OT_W'(mem_resp_i.r.id);
        if (r_id_ok && ar_ot_q[rs].valid) begin
          rc = ar_ot_q[rs].core;
          if (!r_held_found[rc]) begin
            core_resp_o[rc].r_valid = 1'b1;
            core_resp_o[rc].r       = mem_resp_i.r;
            core_resp_o[rc].r.id    = ar_ot_q[rs].orig_id;
            mem_req_o.r_ready = core_req_i[rc].r_ready;
            if (core_req_i[rc].r_ready) begin
              r_fire = 1'b1;
              if (mem_resp_i.r.last) begin
                ar_ot_d[rs].valid = 1'b0;
                if (ar_ot_cnt_d != '0) ar_ot_cnt_d = ar_ot_cnt_d - 1'b1;
              end
            end
          end
          // else a parked ATOP R is being replayed to this core this cycle;
          // the incoming beat is withheld (bounded by the core's r_ready).
        end else if (r_id_ok && aw_ot_q[rs].valid && aw_ot_q[rs].expect_r) begin
          // Atomic R (ATOP load/swap/compare) — same core/id as parent AW
          rc = aw_ot_q[rs].core;
          if (slot_applied(inv_ot_q[rs]) && !r_held_found[rc]) begin
            core_resp_o[rc].r_valid = 1'b1;
            core_resp_o[rc].r       = mem_resp_i.r;
            core_resp_o[rc].r.id    = aw_ot_q[rs].orig_id;
            mem_req_o.r_ready = core_req_i[rc].r_ready;
            if (core_req_i[rc].r_ready && mem_resp_i.r.last) begin
              r_fire = 1'b1;
              aw_ot_d[rs].expect_r = 1'b0;
              if (aw_ot_d[rs].b_done) begin
                aw_ot_d[rs].valid = 1'b0;
                if (aw_ot_cnt_d != '0) aw_ot_cnt_d = aw_ot_cnt_d - 1'b1;
              end
            end
          end else if (!aw_ot_q[rs].r_held) begin
            // Park the beat like B: consume it now, replay once the
            // invalidation has been applied. Withholding it (r_ready=0)
            // stalls the shared R channel and deadlocks against
            // inv_fill_hold — the fill the delivery waits on can be queued
            // behind this very beat.
            mem_req_o.r_ready   = 1'b1;
            aw_ot_d[rs].r_held  = 1'b1;
            aw_ot_d[rs].r_data  = mem_resp_i.r.data;
            aw_ot_d[rs].r_resp  = mem_resp_i.r.resp;
            aw_ot_d[rs].r_user  = mem_resp_i.r.user;
            aw_ot_d[rs].r_last  = mem_resp_i.r.last;
          end
          // else r_held already set while still unapplied: withhold — only
          // reachable for a multi-beat ATOP R, which the downstream
          // axi_riscv_amos never emits (single-beat read result).
        end else begin
          mem_req_o.r_ready = 1'b1;
        end
      end

      // Starve counters
      for (int unsigned c = 0; c < NC; c++) begin
        if (aw_fire && aw_winner == c[CID_W-1:0]) aw_starve_d[c] = '0;
        else if (aw_req[c] && AXI_STARVE_LIMIT != 0 &&
                 aw_starve_q[c] < AXI_STARVE_LIMIT[ST_W-1:0])
          aw_starve_d[c] = aw_starve_q[c] + 1'b1;
        else if (!aw_req[c]) aw_starve_d[c] = '0;

        if (ar_fire && ar_winner == c[CID_W-1:0]) ar_starve_d[c] = '0;
        else if (ar_req[c] && AXI_STARVE_LIMIT != 0 &&
                 ar_starve_q[c] < AXI_STARVE_LIMIT[ST_W-1:0])
          ar_starve_d[c] = ar_starve_q[c] + 1'b1;
        else if (!ar_req[c]) ar_starve_d[c] = '0;
      end
    end

    always_comb begin
      for (int unsigned s = 0; s < OT_MAX; s++) begin
        b_predecessors_d[s] = b_predecessors_q[s] & ~b_completed;
      end
      if (aw_fire) begin
        for (int unsigned s = 0; s < OT_MAX; s++) begin
          b_predecessors_d[aw_free_slot][s] = aw_ot_q[s].valid &&
              !aw_ot_q[s].b_done && !b_completed[s] &&
              (aw_ot_q[s].core == aw_winner) &&
              (aw_ot_q[s].orig_id == core_req_i[aw_winner].aw.id);
        end
      end
    end

    assign coh_split_conflict_o = w_busy_q && |aw_req && (aw_winner != w_owner_q) &&
                                  core_req_i[aw_winner].w_valid;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        inv_pend_q       <= '0;
        inv_pend_tgt_q   <= '0;
        inv_pend_valid_q <= 1'b0;
        inv_pend_slot_q  <= '0;
        aw_hold_q <= 1'b0;
        ar_hold_q <= 1'b0;
        aw_hold_owner_q <= '0;
        ar_hold_owner_q <= '0;
        aw_hold_slot_q <= '0;
        ar_hold_slot_q <= '0;
        aw_rr_q     <= '0;
        ar_rr_q     <= '0;
        ar_ot_cnt_q <= '0;
        aw_ot_cnt_q <= '0;
        w_owner_q   <= '0;
        w_busy_q    <= 1'b0;
        w_slot_q    <= '0;
        for (int unsigned s = 0; s < OT_MAX; s++) begin
          ar_ot_q[s]  <= '0;
          aw_ot_q[s]  <= '0;
          inv_ot_q[s] <= '0;
          b_predecessors_q[s] <= '0;
        end
        for (int unsigned c = 0; c < NC; c++) begin
          aw_starve_q[c] <= '0;
          ar_starve_q[c] <= '0;
          b_offer_locked_q[c] <= 1'b0;
          b_offer_slot_q[c] <= '0;
        end
      end else begin
        inv_pend_q       <= inv_pend_d;
        inv_pend_tgt_q   <= inv_pend_tgt_d;
        inv_pend_valid_q <= inv_pend_valid_d;
        inv_pend_slot_q  <= inv_pend_slot_d;
        aw_hold_q <= aw_grant && !mem_resp_i.aw_ready;
        ar_hold_q <= ar_grant && !mem_resp_i.ar_ready;
        if (aw_grant && !mem_resp_i.aw_ready && !aw_hold_q) begin
          aw_hold_owner_q <= aw_winner;
          aw_hold_slot_q <= aw_free_slot;
        end
        if (ar_grant && !mem_resp_i.ar_ready && !ar_hold_q) begin
          ar_hold_owner_q <= ar_winner;
          ar_hold_slot_q <= ar_free_slot;
        end
        aw_rr_q     <= aw_rr_d;
        ar_rr_q     <= ar_rr_d;
        ar_ot_cnt_q <= ar_ot_cnt_d;
        aw_ot_cnt_q <= aw_ot_cnt_d;
        w_owner_q   <= w_owner_d;
        w_busy_q    <= w_busy_d;
        w_slot_q    <= w_slot_d;
        for (int unsigned s = 0; s < OT_MAX; s++) begin
          ar_ot_q[s]  <= ar_ot_d[s];
          aw_ot_q[s]  <= aw_ot_d[s];
          inv_ot_q[s] <= inv_ot_d[s];
          b_predecessors_q[s] <= b_predecessors_d[s];
        end
        for (int unsigned c = 0; c < NC; c++) begin
          aw_starve_q[c] <= aw_starve_d[c];
          ar_starve_q[c] <= ar_starve_d[c];
          if (core_resp_o[c].b_valid) begin
            if (core_req_i[c].b_ready) begin
              b_offer_locked_q[c] <= 1'b0;
            end else if (!b_offer_locked_q[c]) begin
              b_offer_locked_q[c] <= 1'b1;
              b_offer_slot_q[c] <= b_offer_slot[c];
            end
          end
        end
      end
    end

    // ================================================================
    // Snoop filter
    // ================================================================
    logic [NC-1:0] sf_present, legacy_sf_present;
    logic          sf_hit, sf_over, legacy_sf_hit, legacy_sf_over;
    assign sf_present = OOO_SF ? (sig_result_valid ? sig_present : sig_present_q) : legacy_sf_present;
    assign sf_hit = OOO_SF ? 1'b0 : legacy_sf_hit;
    assign sf_over = OOO_SF ? aw_fire : legacy_sf_over;

    if (OOO_SF) begin : gen_ooo_coherence
      g6lc_ooo_snoop_filter #(
          .NR_CORES(NC), .NR_ENTRIES(SNOOP_FILTER_ENTRIES),
          .LINE_BYTES(LINE_BYTES), .ADDR_WIDTH(AXI_ADDR_WIDTH)
      ) i_signature (
          .clk_i, .rst_ni,
          .alloc_valid_i(ar_fire | aw_fire),
          .alloc_addr_i(aw_fire ? core_req_i[aw_winner].aw.addr : core_req_i[ar_winner].ar.addr),
          .alloc_core_i(aw_fire ? aw_winner : ar_winner), .alloc_ready_o(sig_alloc_ready),
          .lookup_valid_i(sig_start), .lookup_addr_i(core_req_i[aw_winner].aw.addr),
          .lookup_ready_o(), .result_valid_o(sig_result_valid),
          .present_o(sig_present), .ready_o(sig_initialized)
      );
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          sig_pending_q <= 1'b0;
          sig_done_q <= 1'b0;
          sig_owner_q <= '0;
          sig_present_q <= '1;
        end else begin
          if (sig_start) begin
            sig_pending_q <= 1'b1;
            sig_done_q <= 1'b0;
            sig_owner_q <= aw_winner;
          end
          if (sig_result_valid) begin
            sig_done_q <= 1'b1;
            sig_present_q <= sig_present;
          end
          if (aw_fire) begin
            sig_pending_q <= 1'b0;
            sig_done_q <= 1'b0;
          end
        end
      end
      //pragma translate_off
      always_ff @(posedge clk_i) begin
        if (rst_ni && ar_fire && aw_fire) $fatal(1, "HUB_SIGNATURE_ALLOC_CONFLICT");
      end
      //pragma translate_on
    end else begin : gen_legacy_coherence
      assign sig_initialized = 1'b1;
      assign sig_alloc_ready = 1'b1;
      assign sig_result_valid = 1'b0;
      assign sig_present = '1;
      assign sig_pending_q = 1'b0;
      assign sig_done_q = 1'b0;
      assign sig_owner_q = '0;
      assign sig_present_q = '1;
    end
    logic [AXI_ADDR_WIDTH-1:0] sf_lu_addr, sf_al_addr;
    logic [CID_W-1:0]          sf_al_core;

    assign sf_lu_addr = core_req_i[aw_winner].aw.addr;
    assign sf_al_addr = ar_fire ? core_req_i[ar_winner].ar.addr
                                : core_req_i[aw_winner].aw.addr;
    assign sf_al_core = ar_fire ? ar_winner : aw_winner;

    g6lc_snoop_filter #(
        .Enable     (SNOOP_FILTER_EN && (POLICY == COH_FILTERED)),
        .NR_CORES   (NC),
        .NR_ENTRIES (SNOOP_FILTER_ENTRIES),
        .LINE_BYTES (LINE_BYTES),
        .ADDR_WIDTH (AXI_ADDR_WIDTH)
    ) i_sf (
        .clk_i,
        .rst_ni,
        .alloc_valid_i (aw_fire | ar_fire),
        .alloc_addr_i  (sf_al_addr),
        .alloc_core_i  (sf_al_core),
        .clear_valid_i (1'b0),
        .clear_addr_i  ('0),
        .clear_core_i  ('0),
        .clear_all_i   (1'b0),
        .lookup_valid_i(aw_fire),
        .lookup_addr_i (sf_lu_addr),
        .present_o     (legacy_sf_present),
        .lookup_hit_o  (legacy_sf_hit),
        .overapprox_o  (legacy_sf_over)
    );

    assign coh_sf_hit_o        = sf_hit;
    assign coh_sf_overapprox_o = sf_over;

    // ================================================================
    // LR/SC tracker
    // ================================================================
    logic [NC-1:0] lr_kill_cores;
    logic          lr_kill_v;
    logic [55:0]   lr_kill_line;
    logic          is_atop_aw;
    logic          is_lock_aw;

    assign is_atop_aw = |core_req_i[aw_winner].aw.atop;
    assign is_lock_aw = core_req_i[aw_winner].aw.lock;

    g6lc_lr_sc_tracker #(
        .NR_CORES   (NC),
        .LINE_BYTES (LINE_BYTES),
        .ADDR_WIDTH (AXI_ADDR_WIDTH)
    ) i_lrsc (
        .clk_i,
        .rst_ni,
        .lr_valid_i   (lr_valid_i),
        .lr_addr_i    (lr_addr_i),
        .lr_core_i    (lr_core_i),
        .store_valid_i(aw_fire && aw_may_invalidate),
        .store_addr_i (core_req_i[aw_winner].aw.addr),
        .store_core_i (aw_winner),
        .store_is_sc_i(is_lock_aw && is_atop_aw),  // coarse SC hint
        // The SC probe is tied off deliberately, and it cannot be otherwise at
        // this layer: the hub does not adjudicate SC. g6lc_l2_top forwards AxLOCK
        // downstream on purpose (see its LDEX/STEX note) because the authoritative
        // reservation is the downstream exclusive monitor, so the hub never learns
        // whether an SC succeeded. The tracker's per-core slots are used only to
        // generate kill hints (kill_cores_o -> invalidations), which the hub DOES
        // know about.
        //
        // The former coh_sc_fail_o hung off this probe and was therefore permanently
        // zero — the one hub observability output that could not fire, while
        // coh_inv_fire_o, coh_sf_hit_o, coh_sf_overapprox_o, coh_arb_starve_o,
        // coh_split_conflict_o and coh_lr_kill_o are all really driven. It has been
        // re-pointed at coh_sc_noresv_o, which the hub genuinely observes: an
        // SC-shaped store arriving with no reservation recorded for that core.
        .sc_probe_i   (1'b0),
        .sc_addr_i    ('0),
        .sc_core_i    ('0),
        .sc_ok_o      (),
        .kill_cores_o (lr_kill_cores),
        .kill_line_o  (lr_kill_line),
        .kill_valid_o (lr_kill_v),
        .lr_set_o     (),
        .sc_noresv_o  (coh_sc_noresv_o)
    );

    assign coh_lr_kill_o = lr_kill_v;

    // ================================================================
    // Invalidation request (write + LR-kill union)
    // ================================================================
    coh_inval_t    inv_req;
    logic [NC-1:0] inv_target;
    // Freshly generated obligation for the write accepted this cycle.
    coh_inval_t    inv_new;
    logic [NC-1:0] inv_new_target;
    // Write-owned target subset (before the LR-kill union): distinguishes a
    // write obligation that holds back B from a pure LR-kill, which stamps no
    // slot.
    logic [NC-1:0] inv_wr_target;

    always_comb begin
      inv_new        = '0;
      inv_new_target = '0;
      inv_wr_target  = '0;
      if (aw_fire && aw_may_invalidate) begin
        inv_new.valid     = 1'b1;
        inv_new.dcache    = 1'b1;
        inv_new.icache    = 1'b0;
        inv_new.all_ways  = 1'b0;
        inv_new.line_addr = coh_line_tag(core_req_i[aw_winner].aw.addr, LINE_BYTES);
        unique case (POLICY)
          COH_BROADCAST:
            inv_wr_target = {NC{1'b1}} & ~({{NC-1{1'b0}}, 1'b1} << aw_winner);
          default:
            inv_wr_target = sf_present & ~({{NC-1{1'b0}}, 1'b1} << aw_winner);
        endcase
        inv_new_target = inv_wr_target;
      end
      // Union LR-kill victims (they need D$ inv of the reserved line)
      if (lr_kill_v) begin
        inv_new.valid     = 1'b1;
        inv_new.dcache    = 1'b1;
        inv_new.line_addr = lr_kill_line;
        inv_new_target    = inv_new_target | lr_kill_cores;
      end
    end

    // Retention of an accepted write's invalidation obligation.
    // Previously the request was presented combinationally in the same cycle the
    // AW handshook and simply evaporated if the bus was not ready, so a write
    // could complete with no invalidation ever delivered (HUB_INV_LOSS). The
    // obligation is now held until the bus takes it. AW admission consults only
    // the REGISTERED occupancy, never inv_ready or aw_fire, so no combinational
    // loop is created -- which is why gating AW on inv_ready directly was
    // rejected. A retained entry is presented in preference to a fresh one, and a
    // fresh request that the bus accepts immediately still costs no extra cycle.
    always_comb begin
      inv_pend_d       = inv_pend_q;
      inv_pend_tgt_d   = inv_pend_tgt_q;
      inv_pend_valid_d = inv_pend_valid_q;
      inv_pend_slot_d  = inv_pend_slot_q;
      if (inv_pend_valid_q) begin
        if (inv_ready) inv_pend_valid_d = 1'b0;
      end else if (inv_new.valid && |inv_new_target && !inv_ready) begin
        inv_pend_valid_d = 1'b1;
        inv_pend_d       = inv_new;
        inv_pend_tgt_d   = inv_new_target;
        // A write-owned capture remembers its AW slot; a pure LR-kill leaves a
        // meaningless index that the inv_owed guard at stamp time rejects.
        inv_pend_slot_d  = aw_free_slot;
      end
    end

    always_comb begin
      if (inv_pend_valid_q) begin
        inv_req    = inv_pend_q;
        inv_target = inv_pend_tgt_q;
      end else begin
        inv_req    = inv_new;
        inv_target = inv_new_target;
      end
    end

    assign coh_inv_fire_o = inv_req.valid & inv_ready & |inv_target;

    // ---- Invalidation delivery bookkeeping (AW slots) ----
    // A wait bit falls the cycle after the bus's deq sequence reaches the
    // stamped enqueue sequence -- the pop edge E is visible at E+1 through
    // deq_seq_q. Once all targets are delivered, the settle counter runs up to
    // its cap; stamping below resets both fields for a fresh obligation. This
    // block reads the combinational accept path (inv_ready, coh_inv_fire_o,
    // inv_target, inv_enq_seq), which depends on aw_fire, so it must not share
    // a process with the grant logic that produces aw_fire; it writes only
    // inv_ot_d, which reaches the slots through inv_ot_q.
    always_comb begin
      logic [OT_W-1:0] ss;
      logic            do_stamp;
      do_stamp = 1'b0;
      ss       = '0;
      for (int unsigned s = 0; s < OT_MAX; s++) begin
        inv_ot_d[s] = inv_ot_q[s];
        for (int unsigned c = 0; c < NC; c++) begin
          if (inv_ot_q[s].inv_wait[c] &&
              inv_deq_seq[c] == inv_ot_q[s].inv_need[c])
            inv_ot_d[s].inv_wait[c] = 1'b0;
        end
        inv_ot_d[s].inv_settle = (inv_ot_q[s].inv_wait == '0) ?
            ((inv_ot_q[s].inv_settle == 2'd3) ? 2'd3 :
             inv_ot_q[s].inv_settle + 2'd1) : 2'd0;
      end
      // Freshly accepted write: clean bookkeeping; inv_owed marks a
      // write-owned obligation the bus could not take this cycle (it is
      // captured by inv_pend and stamped into this slot on acceptance).
      if (aw_fire) begin
        inv_ot_d[aw_free_slot].inv_wait   = '0;
        inv_ot_d[aw_free_slot].inv_need   = '0;
        inv_ot_d[aw_free_slot].inv_settle = '0;
        inv_ot_d[aw_free_slot].inv_owed   = |inv_wr_target && !inv_ready;
      end
      // The slot records its delivery obligation the moment the bus accepts
      // it. A fresh obligation belongs to the write firing this cycle; a
      // retained one is claimed by the slot in inv_pend_slot_q (the inv_owed
      // guard ignores a stale slot index left by a pure LR-kill retention).
      if (coh_inv_fire_o) begin
        if (!inv_pend_valid_q) begin
          if (aw_fire && |inv_wr_target) begin
            do_stamp = 1'b1;
            ss       = aw_free_slot;
          end
        end else if (inv_ot_q[inv_pend_slot_q].inv_owed) begin
          do_stamp = 1'b1;
          ss       = inv_pend_slot_q;
        end
        if (do_stamp) begin
          inv_ot_d[ss].inv_wait   = inv_target;
          inv_ot_d[ss].inv_settle = '0;
          inv_ot_d[ss].inv_owed   = 1'b0;
          for (int unsigned c = 0; c < NC; c++)
            inv_ot_d[ss].inv_need[c] = inv_enq_seq[c];
        end
      end
    end

    g6lc_inval_bus #(
        .NR_CORES   (NC),
        .DEPTH      (INVAL_DEPTH),
        .LINE_BYTES (LINE_BYTES)
    ) i_inval (
        .clk_i,
        .rst_ni,
        .inv_req_i       (inv_req),
        .inv_target_i    (inv_target),
        .inv_ready_o     (inv_ready),
        .inv_core_o      (inv_bus_o),
        .inv_core_ready_i(inv_bus_ready),
        .inv_stall_o     (),
        .inv_coalesce_o  (),
        .inv_enq_seq_o   (inv_enq_seq),
        .inv_deq_seq_o   (inv_deq_seq)
    );

    //pragma translate_off
    // N1d/T10g hub stall dump (+smt_stats): birth-stamp AR/AW slots; when a
    // slot outlives CS_STALL_GAP cycles it re-dumps per additional gap
    // (bounded to CS_DUMP_MAX), and dumps again at final while any slot is
    // live. The ring-32 boot hangs with a drain pending ~6 M cycles; this
    // pinpoints whether a hub slot/held response is the wedge.
    bit cs_en;
    longint unsigned cs_cyc;
    int unsigned cs_dump_cnt;
    longint signed cs_ar_birth[OT_MAX], cs_aw_birth[OT_MAX];
    function automatic void cs_stall_dump(input string why);
      for (int unsigned s = 0; s < OT_MAX; s++) begin
        if (ar_ot_q[s].valid)
          $display("[coh-stall] %s cyc=%0d ar[%0d] core=%0d oid=%0d xr=%0d bdone=%0d bh=%0d rh=%0d line=%h owed=%0d invw=%h",
                   why, cs_cyc, s, ar_ot_q[s].core, ar_ot_q[s].orig_id,
                   ar_ot_q[s].expect_r, ar_ot_q[s].b_done, ar_ot_q[s].b_held,
                   ar_ot_q[s].r_held, ar_ot_q[s].line_addr,
                   inv_ot_q[s].inv_owed, inv_ot_q[s].inv_wait);
        if (aw_ot_q[s].valid)
          $display("[coh-stall] %s cyc=%0d aw[%0d] core=%0d oid=%0d xr=%0d bdone=%0d bh=%0d rh=%0d rl=%0d line=%h owed=%0d invw=%h invs=%0d",
                   why, cs_cyc, s, aw_ot_q[s].core, aw_ot_q[s].orig_id,
                   aw_ot_q[s].expect_r, aw_ot_q[s].b_done, aw_ot_q[s].b_held,
                   aw_ot_q[s].r_held, aw_ot_q[s].r_last, aw_ot_q[s].line_addr,
                   inv_ot_q[s].inv_owed, inv_ot_q[s].inv_wait,
                   inv_ot_q[s].inv_settle);
      end
      for (int unsigned c = 0; c < NC; c++)
        $display("[coh-stall] %s cyc=%0d inv[%0d] v=%0d rdy=%0d line=%h ways=%0d pendv=%0d pendline=%h enq=%0d deq=%0d",
                 why, cs_cyc, c, inv_bus_o[c].valid, inv_bus_ready[c],
                 inv_bus_o[c].line_addr, inv_bus_o[c].all_ways,
                 inv_pend_q.valid, inv_pend_q.line_addr,
                 inv_enq_seq[c], inv_deq_seq[c]);
      $display("[coh-stall] %s cyc=%0d arh=%0d ahs=%0d aho=%0d awh=%0d aws=%0d awo=%0d awll=%h ifh=%h sigp=%0d",
               why, cs_cyc, ar_hold_q, ar_hold_slot_q, ar_hold_owner_q,
               aw_hold_q, aw_hold_slot_q, aw_hold_owner_q,
               ar_wr_line_live, inv_fill_hold, sig_pending_q);
    endfunction
    initial begin
      cs_en = $test$plusargs("smt_stats");
      cs_cyc = 0; cs_dump_cnt = 0;
      for (int s = 0; s < OT_MAX; s++) begin
        cs_ar_birth[s] = -1; cs_aw_birth[s] = -1;
      end
    end
    always @(posedge clk_i) begin
      if (!rst_ni) begin
        cs_cyc <= 0;
        for (int s = 0; s < OT_MAX; s++) begin
          cs_ar_birth[s] <= -1; cs_aw_birth[s] <= -1;
        end
      end else if (cs_en) begin
        bit cs_fire;
        cs_cyc <= cs_cyc + 1;
        cs_fire = 0;
        for (int s = 0; s < OT_MAX; s++) begin
          if (ar_ot_q[s].valid && cs_ar_birth[s] < 0) cs_ar_birth[s] <= cs_cyc;
          if (!ar_ot_q[s].valid) cs_ar_birth[s] <= -1;
          if (aw_ot_q[s].valid && cs_aw_birth[s] < 0) cs_aw_birth[s] <= cs_cyc;
          if (!aw_ot_q[s].valid) cs_aw_birth[s] <= -1;
          if (cs_ar_birth[s] >= 0 && cs_cyc - cs_ar_birth[s] >= 65536) begin
            cs_fire = 1;
            cs_ar_birth[s] <= cs_cyc;
          end
          if (cs_aw_birth[s] >= 0 && cs_cyc - cs_aw_birth[s] >= 65536) begin
            cs_fire = 1;
            cs_aw_birth[s] <= cs_cyc;
          end
        end
        if (cs_fire && cs_dump_cnt < 8) begin
          cs_stall_dump("slot-age");
          cs_dump_cnt <= cs_dump_cnt + 1;
        end
      end
    end
    final begin
      if (cs_en) cs_stall_dump("final");
    end
    //pragma translate_on

  end

endmodule
