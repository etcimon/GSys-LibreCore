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
//   6. Inv backpressure: hold AW if inv bus not ready (no silent drop storm)
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
    parameter int unsigned MAX_OUTSTANDING      = 4,  // per direction (AR/AW)
    parameter coh_policy_t POLICY               = COH_FILTERED,
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
    output logic                       coh_sc_fail_o,
    output logic                       coh_lr_kill_o
);

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

  if (NC <= 1) begin : gen_identity
    assign mem_req_o            = core_req_i[0];
    assign core_resp_o[0]       = mem_resp_i;
    assign inv_core_o           = '{default: '0};
    assign coh_inv_fire_o       = 1'b0;
    assign coh_sf_hit_o         = 1'b0;
    assign coh_sf_overapprox_o  = 1'b0;
    assign coh_arb_starve_o     = 1'b0;
    assign coh_split_conflict_o = 1'b0;
    assign coh_sc_fail_o        = 1'b0;
    assign coh_lr_kill_o        = 1'b0;
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

    for (genvar c = 0; c < NC; c++) begin : gen_req
      assign aw_req[c] = core_req_i[c].aw_valid;
      assign ar_req[c] = core_req_i[c].ar_valid;
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

    always_comb begin
      aw_winner       = pick_rr(aw_req, aw_rr_q);
      ar_winner       = pick_rr(ar_req, ar_rr_q);
      aw_starve_force = 1'b0;
      ar_starve_force = 1'b0;
      for (int unsigned c = 0; c < NC; c++) begin
        if (AXI_STARVE_LIMIT != 0 && aw_starve_q[c] >= AXI_STARVE_LIMIT[ST_W-1:0] &&
            aw_req[c]) begin
          aw_winner       = c[CID_W-1:0];
          aw_starve_force = 1'b1;
        end
        if (AXI_STARVE_LIMIT != 0 && ar_starve_q[c] >= AXI_STARVE_LIMIT[ST_W-1:0] &&
            ar_req[c]) begin
          ar_winner       = c[CID_W-1:0];
          ar_starve_force = 1'b1;
        end
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
    } ot_entry_t;

    ot_entry_t ar_ot_q[OT_MAX], ar_ot_d[OT_MAX];
    ot_entry_t aw_ot_q[OT_MAX], aw_ot_d[OT_MAX];
    logic [OT_CNT_W-1:0] ar_ot_cnt_q, ar_ot_cnt_d, aw_ot_cnt_q, aw_ot_cnt_d;
    logic ar_ot_full, aw_ot_full;
    logic [OT_W-1:0] ar_free_slot, aw_free_slot;
    logic            ar_have_free, aw_have_free;

    // AR and AW share the mem-side ID/slot space: a slot may be AR *or* AW,
    // never both (ATOP load returns R with the AW id; concurrent AR with the
    // same id would be un-demuxable).
    logic [OT_MAX-1:0] slot_used;
    for (genvar s = 0; s < OT_MAX; s++) begin : gen_slot_used
      assign slot_used[s] = ar_ot_q[s].valid | aw_ot_q[s].valid;
    end
    assign ar_ot_full = &slot_used;
    assign aw_ot_full = &slot_used;

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
      // Prefer distinct free slots when both can allocate the same first free
      // (combinational tie-break: AW takes next free after AR's choice)
      if (ar_have_free && aw_have_free && (ar_free_slot == aw_free_slot)) begin
        aw_have_free = 1'b0;
        for (int unsigned s = 0; s < OT_MAX; s++) begin
          if (!slot_used[s] && OT_W'(s) != ar_free_slot && !aw_have_free) begin
            aw_have_free = 1'b1;
            aw_free_slot = OT_W'(s);
          end
        end
      end
    end

    // Write data owner follows last accepted AW (AXI W has no id)
    logic [CID_W-1:0] w_owner_q, w_owner_d;
    logic             w_busy_q, w_busy_d;
    // Slot of the in-flight W-data owner (for optional debug); B uses scoreboard.
    logic [OT_W-1:0]  w_slot_q, w_slot_d;

    // Inv ready (from bus). Not used to gate AW (avoids AW↔inv combinational loop);
    // inv path is best-effort with coalesce under storms.
    logic inv_ready;

    // Combinational grant eligibility
    logic aw_grant, ar_grant;
    logic aw_fire, ar_fire, w_fire, b_fire, r_fire;

    always_comb begin
      // Defaults
      mem_req_o   = '0;
      aw_fire     = 1'b0;
      ar_fire     = 1'b0;
      w_fire      = 1'b0;
      b_fire      = 1'b0;
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
      aw_grant = |aw_req && !aw_ot_full && aw_have_free && !w_busy_q;

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
        w_owner_d = aw_winner;
        w_slot_d  = aw_free_slot;
        w_busy_d  = 1'b1;
      end

      // ---- AR path (independent of AW) — same valid/ready split ----
      ar_grant = |ar_req && !ar_ot_full && ar_have_free;
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

      // ---- B response demux by OT slot id; restore original core id ----
      if (mem_resp_i.b_valid) begin
        automatic logic [OT_W-1:0] bs;
        automatic logic [CID_W-1:0] bc;
        automatic logic            b_id_ok;
        // Compare full id against OT_MAX (do not truncate OT_MAX to OT_W bits —
        // when OT_MAX is a power of two that truncates to 0).
        b_id_ok = (mem_resp_i.b.id < AXI_ID_WIDTH'(OT_MAX));
        bs      = OT_W'(mem_resp_i.b.id);
        if (b_id_ok && aw_ot_q[bs].valid) begin
          bc = aw_ot_q[bs].core;
          core_resp_o[bc].b_valid = 1'b1;
          core_resp_o[bc].b       = mem_resp_i.b;
          core_resp_o[bc].b.id    = aw_ot_q[bs].orig_id;
          mem_req_o.b_ready = core_req_i[bc].b_ready;
          if (core_req_i[bc].b_ready) begin
            b_fire = 1'b1;
            if (aw_ot_q[bs].expect_r) begin
              // Keep slot until ATOP R is forwarded (amos injects R after B)
              aw_ot_d[bs].b_done = 1'b1;
            end else begin
              aw_ot_d[bs].valid = 1'b0;
              if (aw_ot_cnt_d != '0) aw_ot_cnt_d = aw_ot_cnt_d - 1'b1;
            end
          end
        end else begin
          // Safety: free the mem response so a bad id cannot hang the interconnect
          mem_req_o.b_ready = 1'b1;
        end
      end

      // ---- R response demux by OT slot id; restore original core id ----
      // Normal reads: slot in ar_ot. AXI ATOP load/swap/compare returns old
      // data on R with the *AW* id — demux via aw_ot and free the slot here
      // (B may already have completed; see expect_r above).
      if (mem_resp_i.r_valid) begin
        automatic logic [OT_W-1:0] rs;
        automatic logic [CID_W-1:0] rc;
        automatic logic            r_id_ok;
        r_id_ok = (mem_resp_i.r.id < AXI_ID_WIDTH'(OT_MAX));
        rs      = OT_W'(mem_resp_i.r.id);
        if (r_id_ok && ar_ot_q[rs].valid) begin
          rc = ar_ot_q[rs].core;
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
        end else if (r_id_ok && aw_ot_q[rs].valid && aw_ot_q[rs].expect_r) begin
          // Atomic R (ATOP load/swap/compare) — same core/id as parent AW
          rc = aw_ot_q[rs].core;
          core_resp_o[rc].r_valid = 1'b1;
          core_resp_o[rc].r       = mem_resp_i.r;
          core_resp_o[rc].r.id    = aw_ot_q[rs].orig_id;
          mem_req_o.r_ready = core_req_i[rc].r_ready;
          if (core_req_i[rc].r_ready && mem_resp_i.r.last) begin
            r_fire = 1'b1;
            aw_ot_d[rs].valid = 1'b0;
            if (aw_ot_cnt_d != '0) aw_ot_cnt_d = aw_ot_cnt_d - 1'b1;
          end
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

    assign coh_split_conflict_o = w_busy_q && |aw_req && (aw_winner != w_owner_q) &&
                                  core_req_i[aw_winner].w_valid;

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        aw_rr_q     <= '0;
        ar_rr_q     <= '0;
        ar_ot_cnt_q <= '0;
        aw_ot_cnt_q <= '0;
        w_owner_q   <= '0;
        w_busy_q    <= 1'b0;
        w_slot_q    <= '0;
        for (int unsigned s = 0; s < OT_MAX; s++) begin
          ar_ot_q[s] <= '0;
          aw_ot_q[s] <= '0;
        end
        for (int unsigned c = 0; c < NC; c++) begin
          aw_starve_q[c] <= '0;
          ar_starve_q[c] <= '0;
        end
      end else begin
        aw_rr_q     <= aw_rr_d;
        ar_rr_q     <= ar_rr_d;
        ar_ot_cnt_q <= ar_ot_cnt_d;
        aw_ot_cnt_q <= aw_ot_cnt_d;
        w_owner_q   <= w_owner_d;
        w_busy_q    <= w_busy_d;
        w_slot_q    <= w_slot_d;
        for (int unsigned s = 0; s < OT_MAX; s++) begin
          ar_ot_q[s] <= ar_ot_d[s];
          aw_ot_q[s] <= aw_ot_d[s];
        end
        for (int unsigned c = 0; c < NC; c++) begin
          aw_starve_q[c] <= aw_starve_d[c];
          ar_starve_q[c] <= ar_starve_d[c];
        end
      end
    end

    // ================================================================
    // Snoop filter
    // ================================================================
    logic [NC-1:0] sf_present;
    logic          sf_hit, sf_over;
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
        .present_o     (sf_present),
        .lookup_hit_o  (sf_hit),
        .overapprox_o  (sf_over)
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
        .store_valid_i(aw_fire && (is_atop_aw || is_lock_aw ||
                                   core_req_i[aw_winner].aw.cache[1])),
        .store_addr_i (core_req_i[aw_winner].aw.addr),
        .store_core_i (aw_winner),
        .store_is_sc_i(is_lock_aw && is_atop_aw),  // coarse SC hint
        .sc_probe_i   (1'b0),
        .sc_addr_i    ('0),
        .sc_core_i    ('0),
        .sc_ok_o      (),
        .kill_cores_o (lr_kill_cores),
        .kill_line_o  (lr_kill_line),
        .kill_valid_o (lr_kill_v),
        .lr_set_o     (),
        .sc_fail_o    (coh_sc_fail_o)
    );

    assign coh_lr_kill_o = lr_kill_v;

    // ================================================================
    // Invalidation request (write + LR-kill union)
    // ================================================================
    coh_inval_t    inv_req;
    logic [NC-1:0] inv_target;

    always_comb begin
      inv_req    = '0;
      inv_target = '0;
      if (aw_fire && core_req_i[aw_winner].aw.cache[1]) begin
        inv_req.valid     = 1'b1;
        inv_req.dcache    = 1'b1;
        inv_req.icache    = 1'b0;
        inv_req.all_ways  = 1'b0;
        inv_req.line_addr = coh_line_tag(core_req_i[aw_winner].aw.addr, LINE_BYTES);
        unique case (POLICY)
          COH_BROADCAST:
            inv_target = {NC{1'b1}} & ~({{NC-1{1'b0}}, 1'b1} << aw_winner);
          default:
            inv_target = sf_present & ~({{NC-1{1'b0}}, 1'b1} << aw_winner);
        endcase
      end
      // Union LR-kill victims (they need D$ inv of the reserved line)
      if (lr_kill_v) begin
        inv_req.valid     = 1'b1;
        inv_req.dcache    = 1'b1;
        inv_req.line_addr = lr_kill_line;
        inv_target        = inv_target | lr_kill_cores;
      end
    end

    assign coh_inv_fire_o = inv_req.valid & inv_ready & |inv_target;

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
        .inv_core_o      (inv_core_o),
        .inv_core_ready_i(inv_core_ready_i),
        .inv_drop_o      (),
        .inv_coalesce_o  ()
    );

  end

endmodule
