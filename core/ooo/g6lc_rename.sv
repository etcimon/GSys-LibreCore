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
    parameter int unsigned CKPT_DEPTH  = 8,
    // U6/Phase4: architectural namespaces. The PHYSICAL pool stays shared —
    // that sharing is what makes SMT cheaper than two cores — so only the maps
    // and checkpoints are per hart. NR_HARTS=1 reproduces the previous state
    // exactly, including the reset bindings below.
    parameter int unsigned NR_HARTS    = 1,
    // U6/Phase5: floating-point register class. SPLIT from the integer class —
    // separate map, freelist, busy table and physical pool — rather than
    // widening one shared file. Reasons, in order of weight:
    //   * PRF ports dominate area (one added write port measured at +7,681
    //     generic cells), and FMA's rs3 read port is needed only by FP; a split
    //     file keeps integer-only configurations paying nothing for it.
    //   * FP f0 is an ordinary writable register while integer x0 is hardwired
    //     zero, and the code leans on physical 0 meaning "no destination". A
    //     split file simply has no zero-register exception to thread through.
    //   * FLen can exceed XLEN (RV32 + RVD), so a unified file would widen the
    //     integer entries for no integer benefit.
    //   * The in-order baseline already splits GPR and FPR.
    // FPRF_ENTRIES = 0 disables the class entirely and is bit-identical to the
    // integer-only design.
    parameter int unsigned FPRF_ENTRIES = 0,
    parameter int unsigned FPRF_W       = 1
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic flush_i,
    // Per-hart flush (hart park/reset/trap). Reclaims exactly that hart's
    // physical registers and clears its checkpoints, leaving the peer's
    // allocations and speculation live. Tie low for a global-flush-only core.
    input  logic [(NR_HARTS<1?1:NR_HARTS)-1:0] flush_hart_i,
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
    // Owning hart per dispatch port. Constant 0 when NR_HARTS==1.
    input  logic [NR_PORTS-1:0][(NR_HARTS<=1?1:$clog2(NR_HARTS))-1:0] hart_i,
    input  logic [NR_PORTS-1:0]       valid_i,
    input  logic [NR_PORTS-1:0][4:0]  rs1_i,
    input  logic [NR_PORTS-1:0][4:0]  rs2_i,
    input  logic [NR_PORTS-1:0][4:0]  rd_i,
    input  logic [NR_PORTS-1:0]       need_rd_i,
    input  logic [NR_PORTS-1:0]       is_branch_i,
    // FP class selectors, one per operand. Tie low when FPRF_ENTRIES==0.
    input  logic [NR_PORTS-1:0]       is_fpr_rd_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs1_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs2_i,
    // Third source. There is no rs3 field in the scoreboard entry: the caller
    // extracts it from result[4:0], which the FP compute ops overload as the
    // register number (is_imm_fpr covers FADD:FSUB as well as FMADD:FNMADD).
    // FP-only, so it has no integer counterpart here.
    input  logic [NR_PORTS-1:0][4:0]  rs3_i,
    input  logic [NR_PORTS-1:0]       is_fpr_rs3_i,
    // FP physical tags travel on their own ports: the two classes index
    // different files, so overloading one tag would force the consumer to
    // re-derive the class to know which file to read.
    output logic [NR_PORTS-1:0][PRF_W-1:0] prs1_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prs2_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prd_o,
    output logic [NR_PORTS-1:0][PRF_W-1:0] prd_old_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprs1_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprs2_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprs3_o,
    output logic [NR_PORTS-1:0]             rs3_ready_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprd_o,
    output logic [NR_PORTS-1:0][FPRF_W-1:0] fprd_old_o,
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
    input  logic [NR_WB-1:0]             fwb_valid_i,
    input  logic [NR_WB-1:0][FPRF_W-1:0] fwb_prd_i,
    // Multi-port free at commit (up to NR_FREE = NrCommitPorts)
    input  logic [NR_FREE-1:0]            free_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] free_prd_i,
    input  logic [NR_FREE-1:0]             ffree_i,
    input  logic [NR_FREE-1:0][FPRF_W-1:0] ffree_prd_i,
    // Architectural (committed) mapping updates, one per commit port: the
    // destination and the physical register the committing instruction owns.
    // A full flush must restore THIS map. Resetting to identity instead claims
    // architectural register i lives in physical register i, which holds
    // unrelated data as soon as anything has committed, so every committed
    // value is silently lost at the first exception, fence or CSR side effect.
    // Ports are in program order, so a younger commit to the same destination
    // overrides an older one in the same cycle.
    input  logic [NR_FREE-1:0]            commit_valid_i,
    input  logic [NR_FREE-1:0][(NR_HARTS<=1?1:$clog2(NR_HARTS))-1:0] commit_hart_i,
    input  logic [NR_FREE-1:0][4:0]       commit_rd_i,
    input  logic [NR_FREE-1:0][PRF_W-1:0] commit_prd_i,
    input  logic [NR_FREE-1:0]             commit_is_fpr_i,
    input  logic [NR_FREE-1:0][FPRF_W-1:0] commit_fprd_i,
    input  logic                      enable_i
);

  localparam int unsigned NH    = (NR_HARTS < 1) ? 1 : NR_HARTS;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);
  // Per-hart architectural namespaces. free_q/busy_q below stay SHARED: a
  // physical register belongs to the pool, and busy is a property of that
  // register, not of a hart.
  logic [NH-1:0][31:0][PRF_W-1:0] map_q, map_d;
  logic [NH-1:0][31:0][PRF_W-1:0] amap_q, amap_d;
  logic [PRF_ENTRIES-1:0] free_q, free_d;
  logic [PRF_ENTRIES-1:0] busy_q, busy_d;
  // FP class: own map, own pool, own busy table. FPN==1 (FPRF_ENTRIES==0) keeps
  // the whole class a single unused bit that synthesis removes, so an
  // integer-only build is unchanged.
  localparam int unsigned FPN   = (FPRF_ENTRIES < 1) ? 1 : FPRF_ENTRIES;
  localparam bit          FP_EN = (FPRF_ENTRIES >= 32);
  if (PRF_W < 1 || PRF_W < $clog2(PRF_ENTRIES) ||
      FPRF_W < 1 || (FP_EN && FPRF_W < $clog2(FPN))) begin : gen_bad_tag_width
    initial $fatal(1, "g6lc_rename: physical tag width must represent every pool entry");
  end
  logic [NH-1:0][31:0][FPRF_W-1:0] fmap_q, fmap_d;
  logic [NH-1:0][31:0][FPRF_W-1:0] famap_q, famap_d;
  logic [FPN-1:0] ffree_q, ffree_d;
  logic [FPN-1:0] fbusy_q, fbusy_d;
  // Which hart each physical register currently belongs to. The pool is shared,
  // so nothing else records this, and without it a per-hart flush cannot tell
  // which registers to reclaim. Stale on a free register, which is harmless:
  // allocation overwrites it, and the flush below only reclaims non-free ones.
  logic [PRF_ENTRIES-1:0][HID_W-1:0] owner_q, owner_d;
  logic [FPN-1:0][HID_W-1:0] fowner_q, fowner_d;

  // A checkpoint snapshots only its own hart's map, and records whose it is so
  // recovery restores that hart alone and squashes only that hart's younger
  // allocations.
  // The FP map is checkpointed alongside the integer map: one branch, one
  // recovery point for both classes. Splitting the FILES does not mean
  // splitting the control — a branch is a single program-order event.
  logic [CKPT_DEPTH-1:0][31:0][FPRF_W-1:0] ckpt_fmap_q;
  logic [CKPT_DEPTH-1:0][FPN-1:0] ckpt_falloc_q, ckpt_falloc_d;
  logic [NR_PORTS-1:0][31:0][FPRF_W-1:0] ckpt_fmap_c;
  logic [CKPT_DEPTH-1:0][31:0][PRF_W-1:0] ckpt_map_q;
  logic [CKPT_DEPTH-1:0][HID_W-1:0] ckpt_hart_q, ckpt_hart_d;
  // Registers allocated AFTER each checkpoint. A free-list snapshot cannot
  // express this: a register that was live at the checkpoint, freed by an OLDER
  // instruction committing afterwards, and then reallocated to younger work is
  // absent from the snapshot, so recovery never returns it and it leaks
  // permanently. Commit is in order, so nothing allocated after the checkpoint
  // can have committed before the branch resolves, and every such register is
  // safe to return.
  logic [CKPT_DEPTH-1:0][PRF_ENTRIES-1:0]  ckpt_alloc_q, ckpt_alloc_d;
  localparam int unsigned LVL_W = $clog2(CKPT_DEPTH+1);
  // One ring PER HART over a static slice of the slot array. A single shared
  // ring cannot support a per-hart flush or an independent per-hart recovery:
  // removing one hart's checkpoints would punch a hole in the middle of the
  // ring, which a head/count pair cannot represent. A static split is also the
  // partition-before-elastic-policy rule applied to speculation depth; each
  // hart gets CKPT_PER_HART levels rather than competing for a shared pool.
  localparam int unsigned CKPT_PER_HART = (CKPT_DEPTH / NH < 1) ? 1 : CKPT_DEPTH / NH;
  logic [NH-1:0][LVL_W-1:0] ckpt_head_q, ckpt_head_d;
  logic [NH-1:0][LVL_W-1:0] ckpt_cnt_q, ckpt_cnt_d;

  // Ring index within hart h's slice. The largest argument is head + count +
  // NR_PORTS, so two conditional subtractions cover every case.
  function automatic logic [LVL_W-1:0] ckpt_slot(input int unsigned h, input int unsigned v);
    int unsigned t;
    t = v;
    for (int unsigned i = 0; i < 3; i++) if (t >= CKPT_PER_HART) t -= CKPT_PER_HART;
    return LVL_W'(h * CKPT_PER_HART + t);
  endfunction
  // Checkpoint payload captured this cycle: the map and free list as they stand
  // immediately AFTER that port's branch has renamed, so work at or older than
  // the branch survives recovery. One slot per branch — a two-branch group
  // consumes two levels, so each branch unwinds to its own post-rename point.
  // No busy snapshot is kept -- see the restore below.
  logic [NR_PORTS-1:0][31:0][PRF_W-1:0] ckpt_map_c;

  // Find-first as arithmetic, not as a walk (sv-timing A100): the scan
  // `for i: if (fr[i] && pick == 0) pick = i` is a PRF_ENTRIES-deep priority
  // chain that synthesis keeps serial — the mapped rename netlist's worst
  // register-to-register path was 255 cells / 26 ns (Nangate45, fanout
  // excluded), two of these chains in series across the issue ports.
  // The lowest set bit is isolated as an explicit log-depth prefix OR (a bit
  // is the lowest set bit iff it is set and no lower bit is); A143 — the
  // earlier `fr & (~fr + 1)` is the same function, but the live board mapped
  // that incrementer as a carry chain (scoreboard, A140: +31%). OR-ing the
  // indices of a one-hot is a balanced tree. Exact: an empty vector gives 0,
  // as the scan did.
  function automatic logic [PRF_ENTRIES-1:0] lowest_set(input logic [PRF_ENTRIES-1:0] x);
    logic [PRF_ENTRIES-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < PRF_ENTRIES; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction
  function automatic logic [FPN-1:0] flowest_set(input logic [FPN-1:0] x);
    logic [FPN-1:0] below;
    below = x << 1;
    for (int unsigned l = 1; l < FPN; l = l << 1) below = below | (below << l);
    return x & ~below;
  endfunction
  //
  // Lowest free FP phys. Starts at 0, not 1: FP has no hardwired-zero register,
  // so nothing reserves FP physical 0 (and a set bit 0 selects 0, as before).
  function automatic logic [FPRF_W-1:0] pick_ffree(input logic [FPN-1:0] fr);
    logic [FPN-1:0] lowest;
    lowest = flowest_set(fr);
    pick_ffree = '0;
    for (int unsigned i = 0; i < FPN; i++) begin
      if (lowest[i]) pick_ffree = pick_ffree | FPRF_W'(i);
    end
  endfunction

  // Highest free entry (sv-timing A106): the same isolate on the bit-reversed
  // vector. Port 1 picks from the top of the pool and port 0 from the bottom,
  // both from one snapshot, so the second pick no longer waits for the first
  // pick's clear — one incrementer and one demux off the rename chain. Which
  // physical register a destination gets is not architecturally visible.
  function automatic logic [PRF_W-1:0] pick_free_hi(input logic [PRF_ENTRIES-1:0] fr);
    logic [PRF_ENTRIES-1:0] cand, rev, rev_low, highest;
    cand    = fr & ~PRF_ENTRIES'(1);
    rev     = {<<{cand}};
    rev_low = lowest_set(rev);
    highest = {<<{rev_low}};
    pick_free_hi = '0;
    for (int unsigned i = 1; i < PRF_ENTRIES; i++) begin
      if (highest[i]) pick_free_hi = pick_free_hi | PRF_W'(i);
    end
  endfunction

  function automatic logic [FPRF_W-1:0] pick_ffree_hi(input logic [FPN-1:0] fr);
    logic [FPN-1:0] rev, rev_low, highest;
    rev     = {<<{fr}};
    rev_low = flowest_set(rev);
    highest = {<<{rev_low}};
    pick_ffree_hi = '0;
    for (int unsigned i = 0; i < FPN; i++) begin
      if (highest[i]) pick_ffree_hi = pick_ffree_hi | FPRF_W'(i);
    end
  endfunction

  // Lowest free phys ≥1 in current free vector
  function automatic logic [PRF_W-1:0] pick_free(input logic [PRF_ENTRIES-1:0] fr);
    logic [PRF_ENTRIES-1:0] cand, lowest;
    cand   = fr & ~PRF_ENTRIES'(1);
    lowest = lowest_set(cand);
    pick_free = '0;
    for (int unsigned i = 1; i < PRF_ENTRIES; i++) begin
      if (lowest[i]) pick_free = pick_free | PRF_W'(i);
    end
  endfunction

  // A120: retain the one-hot choice for bit-vector updates. Encoding is
  // needed for map/tag outputs, but decoding that tag for free/busy/ckpt
  // writes needlessly puts another selector after allocation.
  function automatic logic [PRF_ENTRIES-1:0] pick_free_mask(
      input logic [PRF_ENTRIES-1:0] fr, input logic high);
    logic [PRF_ENTRIES-1:0] cand, ordered, lowest, reversed, reversed_lowest;
    cand = fr & ~PRF_ENTRIES'(1);
    reversed = {<<{cand}};
    ordered = high ? reversed : cand;
    lowest = lowest_set(ordered);
    reversed_lowest = {<<{lowest}};
    return high ? reversed_lowest : lowest;
  endfunction
  function automatic logic [FPN-1:0] pick_ffree_mask(
      input logic [FPN-1:0] fr, input logic high);
    logic [FPN-1:0] ordered, lowest, reversed, reversed_lowest;
    reversed = {<<{fr}};
    ordered = high ? reversed : fr;
    lowest = flowest_set(ordered);
    reversed_lowest = {<<{lowest}};
    return high ? reversed_lowest : lowest;
  endfunction

  logic [NR_PORTS-1:0][PRF_W-1:0] alloc_prd_c;
  logic [NR_PORTS-1:0] do_alloc;
  logic [NR_PORTS-1:0][FPRF_W-1:0] alloc_fprd_c;
  logic [NR_PORTS-1:0] do_falloc;
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
    automatic logic [FPN-1:0] favail;
    automatic logic [FPRF_W-1:0] fpicked_c;
    automatic int unsigned n_br;
    stall_c = 1'b0;
    avail = free_q;
    favail = ffree_q;
    fpicked_c = '0;
    // Unconditional defaults: a block-local left unassigned on some path is a
    // latch to the elaborator even when every read is guarded.
    picked = '0;
    n_br = 0;
    // Capacity for the first two ports as counts, not as a pick chain
    // (sv-timing A106): "at least one free" is `|cand`, "at least two" is
    // "something is set besides the lowest set bit" (A143: the prefix-OR
    // isolate, not the `cand - 1` decrementer chain), in parallel with nothing.
    // Ports beyond the second keep the serial pick on the remainder.
    begin
      automatic logic [PRF_ENTRIES-1:0] cand;
      automatic logic [FPN-1:0] fcand;
      automatic logic need0, need1, fneed0, fneed1;
      cand   = avail & ~PRF_ENTRIES'(1);
      fcand  = favail;
      need0  = valid_i[0] && need_rd_i[0] && !(FP_EN && is_fpr_rd_i[0]);
      need1  = NR_PORTS > 1 && valid_i[1] && need_rd_i[1] && !(FP_EN && is_fpr_rd_i[1]);
      fneed0 = FP_EN && valid_i[0] && need_rd_i[0] && is_fpr_rd_i[0];
      fneed1 = FP_EN && NR_PORTS > 1 && valid_i[1] && need_rd_i[1] && is_fpr_rd_i[1];
      if ((need0 || need1) && !(|cand)) stall_c = 1'b1;
      if (need0 && need1 && !(|(cand & ~lowest_set(cand)))) stall_c = 1'b1;
      // FP destinations draw on their own pool, so the two classes cannot
      // stall each other out — a benefit the split buys that a shared pool
      // with a common freelist would not.
      if ((fneed0 || fneed1) && !(|fcand)) stall_c = 1'b1;
      if (fneed0 && fneed1 && !(|(fcand & ~flowest_set(fcand)))) stall_c = 1'b1;
      // the remainder for ports >= 2: what the first two would take
      if (need0) begin
        picked = pick_free(avail);
        avail[picked] = 1'b0;
      end
      if (need1) begin
        picked = pick_free_hi(avail);
        avail[picked] = 1'b0;
      end
      if (fneed0) begin
        fpicked_c = pick_ffree(favail);
        favail[fpicked_c] = 1'b0;
      end
      if (fneed1) begin
        fpicked_c = pick_ffree_hi(favail);
        favail[fpicked_c] = 1'b0;
      end
    end
    for (int unsigned p = 2; p < NR_PORTS; p++) begin
      if (valid_i[p] && need_rd_i[p] && !(FP_EN && is_fpr_rd_i[p])) begin
        picked = pick_free(avail);
        if (picked == '0) stall_c = 1'b1;
        else avail[picked] = 1'b0;
      end
      if (FP_EN && valid_i[p] && need_rd_i[p] && is_fpr_rd_i[p]) begin
        fpicked_c = pick_ffree(favail);
        if (!favail[fpicked_c]) stall_c = 1'b1;
        else favail[fpicked_c] = 1'b0;
      end
    end
    // Every branch must own a checkpoint slot before it may dispatch: one
    // taken without a slot could never be unwound correctly. This gate is the
    // same "ungated intent vs registered capacity" shape as the freelist
    // check, so it cannot feed back through can_go.
    // Per-hart capacity: a group may mix harts, so each hart's own slice must
    // hold its own branches.
    for (int unsigned h = 0; h < NH; h++) begin
      n_br = 0;
      for (int unsigned p = 0; p < NR_PORTS; p++)
        n_br += int'(valid_i[p] && is_branch_i[p] && (int'(hart_i[p]) == h));
      if (int'(ckpt_cnt_q[h]) + n_br > CKPT_PER_HART) stall_c = 1'b1;
    end
  end

  assign stall_o = stall_c;

  // A139 design proposal; vocabulary: architecture/RTL-PIPELINE-PLANS.md.
  // svt-plan: begin g6lc_rename status=proposal target=10-adjusted-FO4
  // svt-plan: cone map read, older-lane bypass, free-register allocation,
  // map write and checkpoint capture share one accepted rename group.
  // svt-plan: boundary reserve physical registers/checkpoints and read maps
  // -> resolve same-group dependencies -> publish the complete group.
  // svt-plan: carry per-lane hart, integer/FP class, architectural sources,
  // new/old physical destinations, busy state, checkpoint tag and group epoch.
  // svt-plan: ownership reserve resources atomically; stalled groups hold
  // allocations; flush releases only unpublished reservations exactly once.
  // svt-plan: bypass compare against earlier lanes of the same hart/class,
  // then earlier pending groups; newest matching destination wins, including
  // prd_old for WAW; integer x0 is fixed while FP f0 remains allocatable.
  // svt-plan: recovery checkpoint the logical map at each branch's lane,
  // including older pending writes; reconcile concurrent retire/free/wakeup.
  // svt-plan: effect separates free selection and map read from dependency
  // resolution/write; bounded group windows avoid an unbounded bypass chain.
  // svt-plan: cost group registers and rollback metadata; +1 or more dispatch
  // cycles, with one group/cycle only if each stage has reserved capacity.
  // svt-plan: limit same-hart dependency compare/select and checkpoint copy
  // remain; dispatch/IQ/ROB must share one group acceptance decision.
  // svt-plan: end
  // Re-pipelining contract (sv-timing A124; 2.69 ns on Nangate45). The map
  // tables are read, bypassed within the group and written in one cycle; a
  // stage inside the block would present a stale map to the younger ports.
  // The admissible form is the rename-read / rename-write split with an
  // intra-group bypass carried across the stage (valid_i per port, flush_i /
  // flush_hart_i; no cancel and no transaction id yet — rename precedes the
  // scoreboard, so the protocol pragma waits for an id-less domain). The A122
  // sites map_d / fmap_d / favail are the latency-neutral bypasses first.
  // svt-pipe: require-contract
  // svt-pipe: protocol ren valid=valid_i flush=flush_i
  // svt-pipe: no-cut on=map_d
  // svt-pipe: no-cut on=fmap_d
  // svt-pipe: cycle ren q=map_d d=prd_o hold=valid_i steps=1
  // svt-pipe: cut-ok ren on=prd_o
  always_comb begin
    // Block-locals are declared and defaulted here: one declared inside a
    // conditional scope reads as a latch to the elaborator.
    automatic logic [PRF_W-1:0] p1, p2, old, picked, pick_lo, pick_hi;
    automatic logic [FPRF_W-1:0] f1, f2, f3, fold, fpicked, fpick_lo, fpick_hi;
    automatic logic [PRF_ENTRIES-1:0] squashed, arch_ref, free_rep;
    automatic logic [FPN-1:0] fsquashed, farch_ref, ffree_rep;
    automatic logic [PRF_ENTRIES-1:0] picked_mask, pick_lo_mask, pick_hi_mask;
    automatic logic [FPN-1:0] fpicked_mask, fpick_lo_mask, fpick_hi_mask;
    automatic logic [LVL_W-1:0] level;
    automatic int unsigned rel, n_ret, mis_hart, lvl_rel, same_before;
    p1 = '0; p2 = '0; old = '0; picked = '0;
    squashed = '0; arch_ref = '0; fsquashed = '0; farch_ref = '0;
    free_rep = free_q; ffree_rep = ffree_q;
    level = '0; rel = 0; n_ret = 0; mis_hart = 0; lvl_rel = 0;
    same_before = 0;
    picked_mask = '0;
    fpicked_mask = '0;
    pick_lo_mask = pick_free_mask(free_q, 1'b0);
    pick_hi_mask = pick_free_mask(free_q, 1'b1);
    fpick_lo_mask = pick_ffree_mask(ffree_q, 1'b0);
    fpick_hi_mask = pick_ffree_mask(ffree_q, 1'b1);
    map_d = map_q;
    amap_d = amap_q;
    free_d = free_q;
    busy_d = busy_q;
    owner_d = owner_q;
    fowner_d = fowner_q;
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
    alloc_fprd_c = '0;
    do_falloc = '0;
    fmap_d = fmap_q;
    famap_d = famap_q;
    ffree_d = ffree_q;
    fbusy_d = fbusy_q;
    ckpt_falloc_d = ckpt_falloc_q;
    ckpt_fmap_c = '0;
    fprs1_o = '0;
    fprs2_o = '0;
    fprs3_o = '0;
    fprd_o = '0;
    fprd_old_o = '0;
    rs3_ready_o = '1;
    f1 = '0; f2 = '0; f3 = '0; fold = '0; fpicked = '0;
    do_ckpt = '0;
    ckpt_slot_c = '1;
    ckpt_map_c = '0;
    ckpt_alloc_d = ckpt_alloc_q;
    ckpt_hart_d = ckpt_hart_q;

    begin
      // Both picks from one snapshot of the free lists (sv-timing A106):
      // port 0 the lowest, port 1 the highest. Neither waits for the other's
      // clear; the single-free case (both name the same entry) is caught by
      // the `free_d[picked]` gate at port 1.
      pick_lo  = pick_free(free_d);
      pick_hi  = pick_free_hi(free_d);
      fpick_lo = pick_ffree(ffree_d);
      fpick_hi = pick_ffree_hi(ffree_d);
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        // map_d, not map_q: earlier ports in this same cycle have already written
        // it, so a younger op in the group sees its older sibling's rename and
        // intra-group WAW/WAR resolve without a stall.
        // x0 never consults the map, so physical 0 stays the shared zero for
        // every hart and no per-hart entry is wasted on it. NOTE the class
        // asymmetry: FP f0 is an ordinary register, so the FP path below has no
        // zero special case at all.
        p1  = (rs1_i[p] == 5'd0) ? '0 : map_d[hart_i[p]][rs1_i[p]];
        p2  = (rs2_i[p] == 5'd0) ? '0 : map_d[hart_i[p]][rs2_i[p]];
        old = (rd_i[p] == 5'd0) ? '0 : map_d[hart_i[p]][rd_i[p]];
        prs1_o[p] = p1;
        prs2_o[p] = p2;
        prd_old_o[p] = old;
        rs1_ready_o[p] = (rs1_i[p] == 5'd0) || !busy_q[p1];
        rs2_ready_o[p] = (rs2_i[p] == 5'd0) || !busy_q[p2];
        if (FP_EN) begin
          f1 = fmap_d[hart_i[p]][rs1_i[p]];
          f2 = fmap_d[hart_i[p]][rs2_i[p]];
          f3 = fmap_d[hart_i[p]][rs3_i[p]];
          fold = fmap_d[hart_i[p]][rd_i[p]];
          fprs1_o[p] = f1;
          fprs2_o[p] = f2;
          fprs3_o[p] = f3;
          fprd_old_o[p] = fold;
          // Readiness is taken from whichever class the operand belongs to.
          if (is_fpr_rs1_i[p]) rs1_ready_o[p] = !fbusy_q[f1];
          if (is_fpr_rs2_i[p]) rs2_ready_o[p] = !fbusy_q[f2];
          if (is_fpr_rs3_i[p]) rs3_ready_o[p] = !fbusy_q[f3];
        end
        // Before writeback/free/recovery below, busy_d differs from busy_q
        // only at older ports' allocations. Bypass those tags directly:
        // allocate -> full busy-vector demux -> indexed busy read otherwise
        // puts two dynamic selectors in series. Compare physical tags so
        // this is also exact for aliasing maps; no free/map invariant is
        // needed. Preserve the integer x0 and FP physical-zero asymmetry.
        for (int unsigned e = 0; e < p; e++) begin
          if (do_alloc[e]) begin
            if (!(FP_EN && is_fpr_rs1_i[p]) && rs1_i[p] != 0 &&
                p1 == alloc_prd_c[e]) rs1_ready_o[p] = 1'b0;
            if (!(FP_EN && is_fpr_rs2_i[p]) && rs2_i[p] != 0 &&
                p2 == alloc_prd_c[e]) rs2_ready_o[p] = 1'b0;
          end
          if (FP_EN && do_falloc[e]) begin
            if (is_fpr_rs1_i[p] && f1 == alloc_fprd_c[e]) rs1_ready_o[p] = 1'b0;
            if (is_fpr_rs2_i[p] && f2 == alloc_fprd_c[e]) rs2_ready_o[p] = 1'b0;
            if (is_fpr_rs3_i[p] && f3 == alloc_fprd_c[e]) rs3_ready_o[p] = 1'b0;
          end
        end

        if (FP_EN && valid_i[p] && enable_i && need_rd_i[p] && is_fpr_rd_i[p]) begin
          // FP destination: allocate from the FP pool. No `!= 0` guard — f0 is
          // an ordinary register, so FP physical 0 is a legitimate allocation
          // and the pool starts at 0 rather than 1.
          // Port 1 picks from the top of the pool (sv-timing A106): no wait
          // on port 0's clear. `ffree_d[fpicked]` still gates the single-
          // free case (both picks name the same entry; port 0 took it).
          fpicked = (p == 0) ? fpick_lo : (p == 1) ? fpick_hi : pick_ffree(ffree_d);
          fpicked_mask = (p == 0) ? fpick_lo_mask :
                         (p == 1) ? fpick_hi_mask : pick_ffree_mask(ffree_d, 1'b0);
          if (|(ffree_d & fpicked_mask)) begin
            do_falloc[p] = 1'b1;
            alloc_fprd_c[p] = fpicked;
            ffree_d = ffree_d & ~fpicked_mask;
            fmap_d[hart_i[p]][rd_i[p]] = fpicked;
            fbusy_d = fbusy_d | fpicked_mask;
            fowner_d[fpicked] = hart_i[p];
            fprd_o[p] = fpicked;
            for (int unsigned s = 0; s < CKPT_DEPTH; s++)
              if (ckpt_hart_d[s] == hart_i[p]) ckpt_falloc_d[s] = ckpt_falloc_d[s] | fpicked_mask;
          end
        end else if (valid_i[p] && enable_i && need_rd_i[p]) begin
          // free_d already has earlier ports' allocs removed; port 1 picks
          // the highest free entry from the same snapshot (sv-timing A106),
          // so its pick does not wait on port 0's clear — `free_d[picked]`
          // gates the single-free case where both picks coincide.
          picked = (p == 0) ? pick_lo : (p == 1) ? pick_hi : pick_free(free_d);
          picked_mask = (p == 0) ? pick_lo_mask :
                        (p == 1) ? pick_hi_mask : pick_free_mask(free_d, 1'b0);
          // Exhaustion is reported by the ungated capacity block above; here it
          // simply means no allocation happens this cycle.
          if (|(free_d & picked_mask)) begin
            do_alloc[p] = 1'b1;
            alloc_prd_c[p] = picked;
            free_d = free_d & ~picked_mask;
            owner_d[picked] = hart_i[p];
            map_d[hart_i[p]][rd_i[p]] = picked;
            busy_d = busy_d | picked_mask;
            prd_o[p] = picked;
            // Younger than every live checkpoint OF THIS HART, including one
            // taken earlier in the same group. Marking a peer hart's
            // checkpoints would make its mispredict squash this allocation,
            // which is the aliasing the per-hart namespaces exist to prevent.
            for (int unsigned s = 0; s < CKPT_DEPTH; s++)
              if (ckpt_hart_d[s] == hart_i[p]) ckpt_alloc_d[s] = ckpt_alloc_d[s] | picked_mask;
          end
        end else if (valid_i[p] && enable_i) begin
          prd_o[p] = old;
        end

        // Capture a checkpoint per branch, immediately after that branch's own
        // rename. The capacity block has already guaranteed a slot for every
        // branch in the group, so each branch gets a distinct level and a
        // later mispredict unwinds to exactly its own post-rename point.
        // Checkpoints already taken by OLDER ports of the same hart in this
        // group. Counted from do_ckpt rather than accumulated into a per-hart
        // array, because a variable-indexed unpacked-array update is not a
        // legal assignment target for the strict frontend.
        same_before = 0;
        for (int unsigned e = 0; e < NR_PORTS; e++)
          if ((e < p) && do_ckpt[e] && (hart_i[e] == hart_i[p])) same_before++;
        if (enable_i && valid_i[p] && is_branch_i[p] &&
            (int'(ckpt_cnt_q[hart_i[p]]) + same_before < CKPT_PER_HART)) begin
          do_ckpt[p] = 1'b1;
          ckpt_slot_c[p] = ckpt_slot(int'(hart_i[p]),
                                     int'(ckpt_head_q[hart_i[p]]) +
                                     int'(ckpt_cnt_q[hart_i[p]]) + same_before);
          ckpt_map_c[p] = map_d[hart_i[p]];
          ckpt_fmap_c[p] = fmap_d[hart_i[p]];
          ckpt_hart_d[ckpt_slot_c[p]] = hart_i[p];
          ckpt_falloc_d[ckpt_slot_c[p]] = '0;
          // This branch's own rename is at or older than the branch.
          ckpt_alloc_d[ckpt_slot_c[p]] = '0;
        end
      end
      ckpt_id_o = ckpt_slot_c;
    end

    for (int unsigned p = 1; p < NR_PORTS; p++) begin
      for (int unsigned e = 0; e < p; e++) begin
        // `!is_fpr_rsN` matters once FP exists: x5 and f5 are different
        // registers that share an architectural NUMBER, so an integer producer
        // must not satisfy an FP consumer. do_alloc/do_falloc already separate
        // the producers; this separates the consumers.
        if (valid_i[e] && do_alloc[e] && rs1_i[p] == rd_i[e] && rd_i[e] != 5'd0 &&
            !(FP_EN && is_fpr_rs1_i[p])) begin
          prs1_o[p] = alloc_prd_c[e];
          rs1_ready_o[p] = 1'b0;
        end
        if (valid_i[e] && do_alloc[e] && rs2_i[p] == rd_i[e] && rd_i[e] != 5'd0 &&
            !(FP_EN && is_fpr_rs2_i[p])) begin
          prs2_o[p] = alloc_prd_c[e];
          rs2_ready_o[p] = 1'b0;
        end
        // Same intra-group dependency resolution for the FP class, matched on
        // do_falloc so an integer producer never satisfies an FP consumer of
        // the same architectural number. No rd!=0 filter: f0 is a real
        // destination, so an f0 producer must be seen by an f0 consumer.
        if (FP_EN && valid_i[e] && do_falloc[e]) begin
          if (is_fpr_rs1_i[p] && rs1_i[p] == rd_i[e]) begin
            fprs1_o[p] = alloc_fprd_c[e];
            rs1_ready_o[p] = 1'b0;
          end
          if (is_fpr_rs2_i[p] && rs2_i[p] == rd_i[e]) begin
            fprs2_o[p] = alloc_fprd_c[e];
            rs2_ready_o[p] = 1'b0;
          end
          if (is_fpr_rs3_i[p] && rs3_i[p] == rd_i[e]) begin
            fprs3_o[p] = alloc_fprd_c[e];
            rs3_ready_o[p] = 1'b0;
          end
        end
      end
    end

    for (int unsigned w = 0; w < NR_WB; w++) begin
      if (wb_valid_i[w] && wb_prd_i[w] != '0) busy_d[wb_prd_i[w]] = 1'b0;
      // No `!= 0` guard: FP physical 0 is a real destination.
      if (FP_EN && fwb_valid_i[w]) fbusy_d[fwb_prd_i[w]] = 1'b0;
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
        free_rep[free_prd_i[f]] = 1'b1;
      end
      if (FP_EN && ffree_i[f]) begin
        ffree_d[ffree_prd_i[f]] = 1'b1;
        fbusy_d[ffree_prd_i[f]] = 1'b0;
        ffree_rep[ffree_prd_i[f]] = 1'b1;
      end
    end

    for (int unsigned h = 0; h < NH; h++) begin
      n_ret = 0;  // reused as this hart's new-checkpoint count
      for (int unsigned p = 0; p < NR_PORTS; p++)
        if (do_ckpt[p] && (int'(hart_i[p]) == h)) n_ret++;
      ckpt_cnt_d[h] = ckpt_cnt_q[h] + LVL_W'(n_ret);
    end
    n_ret = 0;

    // Recovery restores the map, but free/busy are REPAIRED rather than
    // reinstated. The squashed set is exactly those registers that were free at
    // the checkpoint and are no longer free: every allocation made after the
    // branch, i.e. the registers whose producers are being discarded. Returning
    // only those preserves progress that happened after the checkpoint -- commit
    // frees stay freed, and a busy bit already cleared by a writeback stays
    // cleared. Reinstating whole snapshots resurrected completed producers (a
    // permanent wait, since the writeback never repeats) and discarded commit
    // frees (a permanent register leak).
    // The resolving hart is the one that owns the level being unwound, so no
    // separate mispredict-hart input is needed.
    mis_hart = int'(ckpt_hart_q[(int'(mispredict_level_i) < CKPT_DEPTH)
                                ? mispredict_level_i : '0]);
    if (mispredict_i && ckpt_cnt_q[mis_hart] != 0) begin
      // Unwind to the resolving branch, defaulting to the youngest checkpoint.
      // Restoring level k consumes checkpoint k and discards every younger one
      // in a single step, so nothing leaks when an older branch resolves. The
      // level is a ring slot, so its age is its distance from the head; a slot
      // outside the live window (retired, or an untagged resolve) falls back to
      // the youngest checkpoint.
      // mispredict_level_i is an ABSOLUTE slot (ckpt_id_o is), while head/count
      // are offsets inside the hart's slice, so convert before comparing.
      lvl_rel = (int'(mispredict_level_i) < CKPT_DEPTH)
                ? (int'(mispredict_level_i) - mis_hart * CKPT_PER_HART)
                : CKPT_PER_HART;
      rel = (lvl_rel >= int'(ckpt_head_q[mis_hart]))
            ? (lvl_rel - int'(ckpt_head_q[mis_hart]))
            : (lvl_rel + CKPT_PER_HART - int'(ckpt_head_q[mis_hart]));
      if ((lvl_rel >= CKPT_PER_HART) || (rel >= int'(ckpt_cnt_q[mis_hart])))
        rel = int'(ckpt_cnt_q[mis_hart]) - 1;
      level = ckpt_slot(mis_hart, int'(ckpt_head_q[mis_hart]) + rel);
      // ckpt_alloc_q[level] only ever accumulated this checkpoint's own hart's
      // allocations, so the squash cannot reach a peer hart's registers.
      // A147: the squash is taken against the free list before this cycle's
      // allocations (registered list + commit frees), not against free_d
      // after the picks: a mispredict cycle never allocates (the controller
      // raises flush_unissued on every mispredict and dispatch's can_go —
      // enable_i — excludes it; asserted below), so both are the same set and
      // the repair no longer waits on the allocation picks.
      squashed = ckpt_alloc_q[level] & ~free_rep;
      map_d[ckpt_hart_q[level]] = ckpt_map_q[level];
      free_d = free_d | squashed;
      busy_d = busy_d & ~squashed;
      if (FP_EN) begin
        // Same repair-not-reinstate rule as the integer class, on its own pool.
        fsquashed = ckpt_falloc_q[level] & ~ffree_rep;
        fmap_d[ckpt_hart_q[level]] = ckpt_fmap_q[level];
        ffree_d = ffree_d | fsquashed;
        fbusy_d = fbusy_d & ~fsquashed;
      end
      // Only the resolving hart's depth unwinds; the peer keeps its own
      // speculation, which is the point of splitting the ring.
      ckpt_cnt_d[mis_hart] = LVL_W'(rel);
    end

    // Retire committed checkpoints from each hart's own head. Bounded by what
    // is live so a stale strobe cannot advance a head past its tail.
    for (int unsigned h = 0; h < NH; h++) begin
      n_ret = 0;
      for (int unsigned c = 0; c < NR_FREE; c++)
        if (ckpt_retire_i[c] && (int'(commit_hart_i[c]) == h)) n_ret++;
      if (n_ret > int'(ckpt_cnt_d[h])) n_ret = int'(ckpt_cnt_d[h]);
      ckpt_head_d[h] = LVL_W'(int'(ckpt_slot(h, int'(ckpt_head_q[h]) + n_ret)) -
                              h * CKPT_PER_HART);
      ckpt_cnt_d[h]  = ckpt_cnt_d[h] - LVL_W'(n_ret);
    end

    // Architectural map tracks commit. A destination that was never renamed
    // (physical 0) leaves its entry alone.
    for (int unsigned c = 0; c < NR_FREE; c++) begin
      if (FP_EN && commit_valid_i[c] && commit_is_fpr_i[c])
        // No rd!=0 / prd!=0 filter: f0 is architectural state like any other.
        famap_d[commit_hart_i[c]][commit_rd_i[c]] = commit_fprd_i[c];
      else if (commit_valid_i[c] && (commit_rd_i[c] != 5'd0) && (commit_prd_i[c] != '0))
        amap_d[commit_hart_i[c]][commit_rd_i[c]] = commit_prd_i[c];
    end

    // Per-hart flush: reclaim exactly this hart's physicals. A register it owns
    // that its OWN committed map still references stays allocated; everything
    // else it owns returns to the shared pool. The peer is untouched, which is
    // the whole reason ownership is tracked.
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

    if (flush_i) begin
      // Full flush: every hart restarts from its own committed map, and the
      // pool holds everything no hart's architectural map references.
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

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      // Each hart gets 31 committed physicals for x1..x31; x0 is never looked
      // up, so physical 0 is the shared zero and costs nothing per hart. With
      // NR_HARTS=1 this is exactly the previous binding (map[0][i] = i, pool
      // from 32), so a single-hart netlist is unchanged.
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
      // Reset ownership matches the reset bindings above, so a per-hart flush
      // before any allocation still reclaims the right set.
      owner_q <= '0;
      for (int unsigned h = 0; h < NH; h++)
        for (int unsigned i = 1; i < 32; i++) owner_q[31 * h + i] <= HID_W'(h);
      ckpt_hart_q <= '0;
      // FP: every hart's f0..f31 gets its own 32 committed physicals, and the
      // pool starts above them. All 32 are bound, not 31, because f0 is real.
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
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (do_ckpt[p]) ckpt_fmap_q[ckpt_slot_c[p]] <= ckpt_fmap_c[p];
      end
      for (int unsigned p = 0; p < NR_PORTS; p++) begin
        if (do_ckpt[p]) ckpt_map_q[ckpt_slot_c[p]] <= ckpt_map_c[p];
      end
    end
  end

  //pragma translate_off
  // A147: the recovery repair above assumes no allocation in a mispredict
  // cycle. Allocation needs enable_i with a valid port.
  always_ff @(posedge clk_i) begin
    if (rst_ni && !flush_i && mispredict_i && enable_i && (|valid_i))
      $error("g6lc_rename: rename enabled in a mispredict-recovery cycle (A147 repair assumes none)");
  end
  //pragma translate_on

endmodule
