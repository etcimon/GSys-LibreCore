// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5.1 multi-port rename (up to NrIssuePorts in one cycle).
// Sequential combinational rename within the cycle so later ports see earlier
// allocations (WAW/WAR correct). Freelist pops N free phys regs from free_d
// (earlier ports already cleared). Precise free+busy+map ckpt on branch.
//
// Package-free ports (NR_WB instead of CVA6Cfg.NrWbPorts) so formal can
// instantiate this module without config_pkg / ariane_pkg elaboration.

module g6lc_rename #(
    parameter int unsigned PRF_ENTRIES = 72,
    parameter int unsigned PRF_W       = 7,
    parameter int unsigned NR_PORTS    = 2,
    parameter int unsigned NR_FREE     = 2,
    parameter int unsigned NR_WB       = 1,
    parameter int unsigned CKPT_DEPTH  = 8
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    input  logic mispredict_i,
    // Checkpoint level to unwind to, i.e. the identity of the resolving branch.
    // Any value at or above the current depth means "the youngest checkpoint",
    // which is the behaviour a caller with no branch tag gets by tying this
    // high. Supplying a real level lets an OLDER branch resolve correctly:
    // without it, recovery always pops the youngest checkpoint, which restores
    // state that still contains work younger than the branch that actually
    // mispredicted, and leaks the intervening checkpoints.
    input  logic [$clog2(CKPT_DEPTH+1)-1:0] mispredict_level_i,
    // Dispatch ports (program order p=0 oldest)
    input  logic [NR_PORTS-1:0]       valid_i,
    input  logic [NR_PORTS-1:0][4:0]  rs1_i,
    input  logic [NR_PORTS-1:0][4:0]  rs2_i,
    input  logic [NR_PORTS-1:0][4:0]  rd_i,
    input  logic [NR_PORTS-1:0]       need_rd_i,
    input  logic [NR_PORTS-1:0]       is_branch_i,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prs1_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prs2_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prd_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prd_old_o,
    output logic [NR_PORTS-1:0]       rs1_ready_o,
    output logic [NR_PORTS-1:0]       rs2_ready_o,
    // Checkpoint level consumed by each port's branch this cycle (the value a
    // caller must present back as mispredict_level_i when that branch later
    // resolves). '1 means the port took no checkpoint. Emitted combinationally
    // for the cycle the group is admitted.
    output logic [NR_PORTS-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_id_o,
    // Retirement of the OLDEST outstanding checkpoint, one strobe per commit
    // port. A branch that has committed can never be unwound to, so without
    // this the pool only ever drains on mispredict or flush and dispatch stalls
    // permanently after CKPT_DEPTH correctly predicted branches. Checkpoints are
    // taken in program order and commit is in program order, so the pool is a
    // ring: allocate at the tail, retire at the head.
    input  logic [NR_FREE-1:0]        ckpt_retire_i,
    output logic                      stall_o,
    // Busy table / freelist
    input  logic [NR_WB-1:0]            wb_valid_i,
    input  logic [NR_WB-1:0][PRF_W-1:0] wb_prd_i,
    // Multi-port free at commit (up to NR_FREE = NrCommitPorts)
    input  logic [NR_FREE-1:0]            free_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] free_prd_i,
    // Architectural (committed) mapping updates, one per commit port: the
    // destination and the physical register the committing instruction owns.
    // A full flush must restore THIS map. Resetting to identity instead claims
    // architectural register i lives in physical register i, which holds
    // unrelated data as soon as anything has committed, so every committed
    // value is silently lost at the first exception, fence or CSR side effect.
    // Ports are in program order, so a younger commit to the same destination
    // overrides an older one in the same cycle.
    input  logic [NR_FREE-1:0]            commit_valid_i,
    input  logic [NR_FREE-1:0][4:0]       commit_rd_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] commit_prd_i,
    input  logic                      enable_i
);

  logic [31:0][PRF_W-1:0] map_q, map_d;
  logic [31:0][PRF_W-1:0] amap_q, amap_d;
  logic [PRF_ENTRIES-1:0] free_q, free_d;
  logic [PRF_ENTRIES-1:0] busy_q, busy_d;

  logic [CKPT_DEPTH-1:0][31:0][PRF_W-1:0] ckpt_map_q;
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0]  ckpt_free_q;
  localparam int unsigned LVL_W = $clog2(CKPT_DEPTH+1);
  logic [LVL_W-1:0] ckpt_head_q, ckpt_head_d;
  logic [LVL_W-1:0] ckpt_cnt_q, ckpt_cnt_d;

  // Ring index for a tail/head walk. The largest argument is head + count +
  // NR_PORTS, so two conditional subtractions cover every case.
  function automatic logic [LVL_W-1:0] ckpt_slot(input int unsigned v);
    int unsigned t;
    t = v;
    for (int unsigned i = 0; i < 3; i++) if (t >= CKPT_DEPTH) t -= CKPT_DEPTH;
    return LVL_W'(t);
  endfunction
  // Checkpoint payload captured this cycle: the map and free list as they stand
  // immediately AFTER that port's branch has renamed, so work at or older than
  // the branch survives recovery. One slot per branch — a two-branch group
  // consumes two levels, so each branch unwinds to its own post-rename point.
  // No busy snapshot is kept -- see the restore below.
  logic [NR_PORTS-1:0][31:0][PRF_W-1:0] ckpt_map_c;
  logic [NR_PORTS-1:0][PRF_ENTRIES-1:0]  ckpt_free_c;

  // Lowest free phys ≥1 in current free vector
  function automatic logic [PRF_W-1:0] pick_free(input logic [PRF_ENTRIES-1:0] fr);
    pick_free = '0;
    for (int unsigned i = 1; i < PRF_ENTRIES; i++) begin
      if (fr[i] && pick_free == '0) pick_free = PRF_W'(i);
    end
  endfunction

  logic [NR_PORTS-1:0][PRF_W-1:0] alloc_prd_c;
  logic [NR_PORTS-1:0] do_alloc;
  logic stall_c;
  logic [NR_PORTS-1:0] do_ckpt;
  logic [NR_PORTS-1:0][$clog2(CKPT_DEPTH+1)-1:0] ckpt_slot_c;

  // Admission capacity, from ungated intent. This must NOT read enable_i:
  // enable_i is the caller's can_go, and can_go consumes stall_o, so gating the
  // capacity test on it closes a combinational loop
  // (can_go -> enable_i -> stall_c -> stall_o -> ren_stall -> can_go).
  // Whether the group *fits* is a property of the group and of the registered
  // free list, not of whether the group is currently allowed to proceed.
  // Registered free state only, which matches the allocation loop below: that
  // loop likewise cannot consume registers freed in this same cycle.
  always_comb begin
    automatic logic [PRF_ENTRIES-1:0] avail;
    automatic logic [PRF_W-1:0] picked;
    automatic int unsigned n_br;
    stall_c = 1'b0;
    avail = free_q;
    // Unconditional defaults: a block-local left unassigned on some path is a
    // latch to the elaborator even when every read is guarded.
    picked = '0;
    n_br = 0;
    for (int unsigned p = 0; p < NR_PORTS; p++) begin
      if (valid_i[p] && need_rd_i[p]) begin
        picked = pick_free(avail);
        if (picked == '0) stall_c = 1'b1;
        else avail[picked] = 1'b0;
      end
    end
    // Every branch must own a checkpoint slot before it may dispatch: one
    // taken without a slot could never be unwound correctly. This gate is the
    // same "ungated intent vs registered capacity" shape as the freelist
    // check, so it cannot feed back through can_go.
    n_br = 0;
    for (int unsigned p = 0; p < NR_PORTS; p++)
      n_br += int'(valid_i[p] && is_branch_i[p]);
    if (int'(ckpt_cnt_q) + n_br > CKPT_DEPTH) stall_c = 1'b1;
  end

  assign stall_o = stall_c;

  always_comb begin
    // Block-locals are declared and defaulted here: one declared inside a
    // conditional scope reads as a latch to the elaborator.
    automatic logic [PRF_W-1:0] p1, p2, old, picked;
    automatic logic [PRF_ENTRIES-1:0] squashed;
    automatic logic [LVL_W-1:0] level;
    automatic int unsigned slots, rel, n_ret;
    p1 = '0; p2 = '0; old = '0; picked = '0;
    squashed = '0; level = '0; slots = 0; rel = 0; n_ret = 0;
    map_d = map_q;
    amap_d = amap_q;
    free_d = free_q;
    busy_d = busy_q;
    ckpt_head_d = ckpt_head_q;
    ckpt_cnt_d  = ckpt_cnt_q;
    prs1_o = '0;
    prs2_o = '0;
    prd_o = '0;
    prd_old_o = '0;
    rs1_ready_o = '1;
    rs2_ready_o = '1;
    alloc_prd_c = '0;
    do_alloc = '0;
    do_ckpt = '0;
    ckpt_slot_c = '1;
    ckpt_map_c = '0;
    ckpt_free_c = '0;

    begin
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        // map_d, not map_q: earlier ports in this same cycle have already written
        // it, so a younger op in the group sees its older sibling's rename and
        // intra-group WAW/WAR resolve without a stall.
        p1  = (rs1_i[p] == 5'd0) ? '0 : map_d[rs1_i[p]];
        p2  = (rs2_i[p] == 5'd0) ? '0 : map_d[rs2_i[p]];
        old = (rd_i[p] == 5'd0) ? '0 : map_d[rd_i[p]];
        prs1_o[p] = p1;
        prs2_o[p] = p2;
        prd_old_o[p] = old;
        rs1_ready_o[p] = (rs1_i[p] == 5'd0) || !busy_d[p1];
        rs2_ready_o[p] = (rs2_i[p] == 5'd0) || !busy_d[p2];

        if (valid_i[p] && enable_i && need_rd_i[p]) begin
          // free_d already has earlier ports' allocs removed
          picked = pick_free(free_d);
          // Exhaustion is reported by the ungated capacity block above; here it
          // simply means no allocation happens this cycle.
          if (picked != '0) begin
            do_alloc[p] = 1'b1;
            alloc_prd_c[p] = picked;
            free_d[picked] = 1'b0;
            map_d[rd_i[p]] = picked;
            busy_d[picked] = 1'b1;
            prd_o[p] = picked;
          end
        end else if (valid_i[p] && enable_i) begin
          prd_o[p] = old;
        end

        // Capture a checkpoint per branch, immediately after that branch's own
        // rename. The capacity block has already guaranteed a slot for every
        // branch in the group, so each branch gets a distinct level and a
        // later mispredict unwinds to exactly its own post-rename point.
        if (enable_i && valid_i[p] && is_branch_i[p] &&
            (int'(ckpt_cnt_q) + slots < CKPT_DEPTH)) begin
          do_ckpt[p] = 1'b1;
          ckpt_slot_c[p] = ckpt_slot(int'(ckpt_head_q) + int'(ckpt_cnt_q) + slots);
          ckpt_map_c[p] = map_d;
          ckpt_free_c[p] = free_d;
          slots++;
        end
      end
      ckpt_id_o = ckpt_slot_c;
    end

    for (int unsigned p = 1; p < NR_PORTS; p++) begin
      for (int unsigned e = 0; e < p; e++) begin
        if (valid_i[e] && do_alloc[e] && rs1_i[p] == rd_i[e] && rd_i[e] != 5'd0) begin
          prs1_o[p] = alloc_prd_c[e];
          rs1_ready_o[p] = 1'b0;
        end
        if (valid_i[e] && do_alloc[e] && rs2_i[p] == rd_i[e] && rd_i[e] != 5'd0) begin
          prs2_o[p] = alloc_prd_c[e];
          rs2_ready_o[p] = 1'b0;
        end
      end
    end

    for (int unsigned w = 0; w < NR_WB; w++) begin
      if (wb_valid_i[w] && wb_prd_i[w] != '0) busy_d[wb_prd_i[w]] = 1'b0;
    end
    for (int unsigned f = 0; f < NR_FREE; f++) begin
      // A freed register is definitionally not awaiting a producer: in-order
      // retire means the reg being released (prd_old) had its writeback land
      // before the overwriting instruction could commit. Clearing busy keeps
      // free/busy exclusive even if the bit was still set, and prevents the
      // restore below from skipping it (a reg already in free_d is not part of
      // `squashed`, so without this clear a stale busy would survive).
      if (free_i[f] && free_prd_i[f] != '0) begin
        free_d[free_prd_i[f]] = 1'b1;
        busy_d[free_prd_i[f]] = 1'b0;
      end
    end

    ckpt_cnt_d = ckpt_cnt_q + LVL_W'($countones(do_ckpt));

    // Recovery restores the map, but free/busy are REPAIRED rather than
    // reinstated. The squashed set is exactly those registers that were free at
    // the checkpoint and are no longer free: every allocation made after the
    // branch, i.e. the registers whose producers are being discarded. Returning
    // only those preserves progress that happened after the checkpoint -- commit
    // frees stay freed, and a busy bit already cleared by a writeback stays
    // cleared. Reinstating whole snapshots resurrected completed producers (a
    // permanent wait, since the writeback never repeats) and discarded commit
    // frees (a permanent register leak).
    if (mispredict_i && ckpt_cnt_q != 0) begin
      // Unwind to the resolving branch, defaulting to the youngest checkpoint.
      // Restoring level k consumes checkpoint k and discards every younger one
      // in a single step, so nothing leaks when an older branch resolves. The
      // level is a ring slot, so its age is its distance from the head; a slot
      // outside the live window (retired, or an untagged resolve) falls back to
      // the youngest checkpoint.
      rel = (int'(mispredict_level_i) >= int'(ckpt_head_q))
            ? (int'(mispredict_level_i) - int'(ckpt_head_q))
            : (int'(mispredict_level_i) + CKPT_DEPTH - int'(ckpt_head_q));
      if ((int'(mispredict_level_i) >= CKPT_DEPTH) || (rel >= int'(ckpt_cnt_q)))
        rel = int'(ckpt_cnt_q) - 1;
      level = ckpt_slot(int'(ckpt_head_q) + rel);
      squashed = ckpt_free_q[level] & ~free_d;
      map_d  = ckpt_map_q[level];
      free_d = free_d | squashed;
      busy_d = busy_d & ~squashed;
      ckpt_cnt_d = LVL_W'(rel);
    end

    // Retire committed checkpoints from the head. Bounded by what is live so a
    // stale strobe cannot advance the head past the tail.
    begin
      n_ret = $countones(ckpt_retire_i);
      if (n_ret > int'(ckpt_cnt_d)) n_ret = int'(ckpt_cnt_d);
      ckpt_head_d = ckpt_slot(int'(ckpt_head_q) + n_ret);
      ckpt_cnt_d  = ckpt_cnt_d - LVL_W'(n_ret);
    end

    // Architectural map tracks commit. A destination that was never renamed
    // (physical 0) leaves its entry alone.
    for (int unsigned c = 0; c < NR_FREE; c++) begin
      if (commit_valid_i[c] && (commit_rd_i[c] != 5'd0) && (commit_prd_i[c] != '0))
        amap_d[commit_rd_i[c]] = commit_prd_i[c];
    end

    if (flush_i) begin
      // Restore committed state: the architectural map, and a free list holding
      // everything it does not reference.
      map_d  = amap_d;
      free_d = '0;
      for (int unsigned i = 1; i < PRF_ENTRIES; i++) free_d[i] = 1'b1;
      for (int unsigned a = 0; a < 32; a++)
        if (amap_d[a] != '0) free_d[amap_d[a]] = 1'b0;
      busy_d = '0;
      ckpt_head_d = '0;
      ckpt_cnt_d  = '0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int unsigned i = 0; i < 32; i++) begin
        map_q[i]  <= PRF_W'(i);
        amap_q[i] <= PRF_W'(i);
      end
      free_q <= '0;
      for (int unsigned i = 32; i < PRF_ENTRIES; i++) free_q[i] <= 1'b1;
      busy_q <= '0;
      ckpt_head_q <= '0;
      ckpt_cnt_q <= '0;
      ckpt_map_q <= '0;
      ckpt_free_q <= '0;
    end else begin
      map_q <= map_d;
      amap_q <= amap_d;
      free_q <= free_d;
      busy_q <= busy_d;
      ckpt_head_q <= ckpt_head_d;
      ckpt_cnt_q <= ckpt_cnt_d;
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (do_ckpt[p]) begin
          ckpt_map_q[ckpt_slot_c[p]]  <= ckpt_map_c[p];
          ckpt_free_q[ckpt_slot_c[p]] <= ckpt_free_c[p];
        end
      end
    end
  end

endmodule
