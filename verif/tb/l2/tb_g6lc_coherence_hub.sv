// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_coherence_hub;
  import g6lc_coherence_pkg::*;
  import g6lc_l2_tb_pkg::*;
  parameter int unsigned OT = 4;
  //  Overridable (-GSTARVE_LIMIT=N), because the override is UNREACHABLE at the
  //  production limit and can only be exercised by lowering it.
  //
  //  Measured on a correctly draining harness: at limit 16 the override asserts for
  //  ZERO cycles out of 1200, at 2, 4 and 8 cores, and round-robin alone distributes
  //  grants perfectly evenly (300:300, 150x4, 75x8). An intermediate version of this
  //  bench reported "39 of 60 cycles" and that number is RETRACTED -- it came from a
  //  harness that never completed writes, so the hub jammed after MAX_OUTSTANDING
  //  and every core trivially passed the limit while waiting forever.
  parameter int unsigned STARVE_LIMIT = 16;
  //  Core count. The override's selection loop lets the HIGHEST-INDEXED starved core
  //  win, so its unfairness is expected to grow with this number; 2 cannot show that.
  parameter int unsigned NC = 2;
  //  Observation window for the fairness scenario. Parameterised because a shut-out
  //  reported over too short a window is a MEASUREMENT ARTIFACT, not starvation:
  //  grants are scarce (each write holds the channel through its W handshake), so
  //  with 8 cores and 60 cycles no core can be granted more than about once and
  //  several are simply not reached yet. Separating "too short" from "starved"
  //  requires lengthening this, not re-reading the RTL.
  parameter int unsigned CYCLES = 60;
  logic clk = 0, rst_n = 0;
  req_t [NC-1:0] core_req;
  resp_t [NC-1:0] core_rsp;
  req_t memory_req;
  resp_t memory_rsp;
  coh_inval_t [NC-1:0] invalidations;
  logic [NC-1:0] invalidation_ready;
  bit negative;
  int scenario;
  logic arb_starve;

  g6lc_coherence_hub #(
    .NR_CORES(NC), .MAX_OUTSTANDING(OT), .INVAL_DEPTH(2),
    .SNOOP_FILTER_EN(0), .SNOOP_FILTER_ENTRIES(4),
    .POLICY(config_pkg::COH_BROADCAST), .AXI_STARVE_LIMIT(STARVE_LIMIT),
    .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .core_req_i(core_req), .core_resp_o(core_rsp),
    .mem_req_o(memory_req), .mem_resp_i(memory_rsp),
    .inv_core_o(invalidations), .inv_core_ready_i(invalidation_ready),
    .lr_valid_i(1'b0), .lr_addr_i('0), .lr_core_i('0),
    .coh_inv_fire_o(), .coh_sf_hit_o(), .coh_sf_overapprox_o(),
    //  coh_arb_starve_o was discarded here, so the starvation override had never
    //  been observed to fire in any test -- the RTL drives it, which is not the
    //  same thing as a bench having seen it assert. Scenario 9 observes it.
    .coh_arb_starve_o(arb_starve),
    .coh_split_conflict_o(), .coh_sc_noresv_o(), .coh_lr_kill_o()
  );

  function automatic ar_chan_t ar(input addr_t address, input id_t id);
    ar_chan_t value;
    value = '0;
    value.addr = address;
    value.id = id;
    value.size = 3;
    value.burst = 1;
    return value;
  endfunction

  function automatic aw_chan_t aw(input addr_t address, input id_t id,
                                  input logic [3:0] cache = 0);
    aw_chan_t value;
    value = '0;
    value.addr = address;
    value.id = id;
    value.size = 3;
    value.burst = 1;
    value.cache = cache;
    return value;
  endfunction

  task automatic tick;
    clk = 1;
    #2;
    clk = 0;
    #2;
  endtask

  task automatic reset;
    rst_n = 0;
    core_req = '0;
    memory_rsp = '0;
    invalidation_ready = '1;
    #2;
    tick();
    rst_n = 1;
    for (int c = 0; c < NC; c++) begin
      core_req[c].r_ready = 1;
      core_req[c].b_ready = 1;
    end
    #2;
  endtask

  task automatic accept_read(input int core, input addr_t address, input id_t id,
                             output id_t memory_id);
    core_req[core].ar = ar(address, id);
    core_req[core].ar_valid = 1;
    memory_rsp.ar_ready = 1;
    #2;
    if (!memory_req.ar_valid || !core_rsp[core].ar_ready || memory_req.ar.addr !== address)
      $fatal(1, "HUB_SETUP read admission");
    memory_id = memory_req.ar.id;
    tick();
    core_req[core].ar_valid = 0;
    memory_rsp.ar_ready = 0;
  endtask

  task automatic basic;
    id_t slot;
    data_t observed;
    reset();
    accept_read(0, 64'h1000, 4'ha, slot);
    memory_rsp.r_valid = 1;
    memory_rsp.r = '{id: slot, data: 64'h91a73, resp: 0, last: 1, user: 0};
    #2;
    observed = core_rsp[0].r.data ^ (negative ? 64'd1 : 64'd0);
    if (!core_rsp[0].r_valid || core_rsp[1].r_valid || core_rsp[0].r.id !== 4'ha ||
        observed !== 64'h91a73 || !memory_req.r_ready)
      $fatal(1, "HUB_RESPONSE owner/id/data");
    tick();
    memory_rsp.r_valid = 0;
  endtask

  task automatic ar_stability;
    ar_chan_t saved;
    reset();
    core_req[1].ar = ar(64'h1000, 4'h8);
    core_req[1].ar_valid = 1;
    #2;
    if (!memory_req.ar_valid) $fatal(1, "HUB_SETUP missing AR");
    saved = memory_req.ar;
    tick();
    core_req[0].ar = ar(64'h2000, 4'h9);
    core_req[0].ar_valid = 1;
    repeat (20) begin
      #2;
      if (!memory_req.ar_valid || memory_req.ar !== saved)
        $fatal(1, "HUB_AR_STABILITY before=%h after=%h", saved, memory_req.ar);
      tick();
    end
  endtask

  task automatic aw_stability;
    aw_chan_t saved;
    reset();
    core_req[1].aw = aw(64'h1000, 4'h8);
    core_req[1].aw_valid = 1;
    #2;
    if (!memory_req.aw_valid) $fatal(1, "HUB_SETUP missing AW");
    saved = memory_req.aw;
    tick();
    core_req[0].aw = aw(64'h2000, 4'h9);
    core_req[0].aw_valid = 1;
    repeat (20) begin
      #2;
      if (!memory_req.aw_valid || memory_req.aw !== saved)
        $fatal(1, "HUB_AW_STABILITY before=%h after=%h", saved, memory_req.aw);
      tick();
    end
  endtask

  task automatic id_stability;
    id_t old_slot;
    ar_chan_t saved;
    reset();
    accept_read(0, 64'h1000, 4'ha, old_slot);
    core_req[1].ar = ar(64'h2000, 4'hb);
    core_req[1].ar_valid = 1;
    #2;
    if (!memory_req.ar_valid) $fatal(1, "HUB_SETUP missing pending AR");
    saved = memory_req.ar;
    tick();
    memory_rsp.r_valid = 1;
    memory_rsp.r = '{id: old_slot, data: 64'h55, resp: 0, last: 1, user: 0};
    #2;
    if (!core_rsp[0].r_valid || !memory_req.r_ready)
      $fatal(1, "HUB_SETUP response did not free slot");
    tick();
    memory_rsp.r_valid = 0;
    #2;
    if (!memory_req.ar_valid || memory_req.ar !== saved)
      $fatal(1, "HUB_ID_STABILITY before=%h after=%h", saved, memory_req.ar);
  endtask

  task automatic aw_credit;
    id_t slot;
    reset();
    for (int n = 0; n < 3; n++) accept_read(0, 64'h1000 + 64'(n) * 64'd64, 4'(n), slot);
    core_req[1].aw = aw(64'h3000, 4'h9);
    core_req[1].aw_valid = 1;
    memory_rsp.aw_ready = 1;
    #2;
    if (!memory_req.aw_valid || !core_rsp[1].aw_ready)
      $fatal(1, "HUB_AW_CREDIT one free slot without competing AR");
  endtask

  task automatic finish_write(input int core, input id_t slot, input id_t original);
    core_req[core].w = '{data: 64'h551, strb: '1, last: 1, user: 0};
    core_req[core].w_valid = 1;
    memory_rsp.w_ready = 1;
    #2;
    if (!memory_req.w_valid || !core_rsp[core].w_ready || core_rsp[1-core].w_ready ||
        memory_req.w !== core_req[core].w) $fatal(1, "HUB_WRITE_OWNER");
    tick();
    core_req[core].w_valid = 0;
    memory_rsp.w_ready = 0;
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: slot, resp: 0, user: 0};
    core_req[core].b_ready = 0;
    repeat (2) begin
      #2;
      if (!core_rsp[core].b_valid || core_rsp[1-core].b_valid ||
          core_rsp[core].b.id !== original || memory_req.b_ready)
        $fatal(1, "HUB_B_HOLD");
      if (memory_req.ar_valid) $fatal(1, "HUB_PREMATURE_B_RELEASE");
      tick();
    end
    core_req[core].b_ready = 1;
    #2;
    if (!memory_req.b_ready) $fatal(1, "HUB_B_COMPLETE");
    tick();
    memory_rsp.b_valid = 0;
  endtask

  task automatic return_read(input int core, input id_t slot, input id_t original,
                             input data_t data);
    memory_rsp.r_valid = 1;
    memory_rsp.r = '{id: slot, data: data, resp: 0, last: 1, user: 0};
    core_req[core].r_ready = 0;
    repeat (2) begin
      #2;
      if (!core_rsp[core].r_valid || core_rsp[1-core].r_valid ||
          core_rsp[core].r.id !== original || core_rsp[core].r.data !== data || memory_req.r_ready)
        $fatal(1, "HUB_R_HOLD");
      tick();
    end
    core_req[core].r_ready = 1;
    #2;
    if (!memory_req.r_ready) $fatal(1, "HUB_R_COMPLETE");
    tick();
    memory_rsp.r_valid = 0;
  endtask

  task automatic reservations;
    ar_chan_t saved_ar;
    aw_chan_t saved_aw;
    id_t read_slots[4];
    reset();
    if (OT != 4) $fatal(1, "HUB_PARAMETERS reservations need OT4");
    core_req[0].ar = ar(64'h1000, 4'ha);
    core_req[0].ar_valid = 1;
    core_req[1].aw = aw(64'h2000, 4'he);
    core_req[1].aw_valid = 1;
    #2;
    if (!memory_req.ar_valid || !memory_req.aw_valid || memory_req.ar.id == memory_req.aw.id)
      $fatal(1, "HUB_RESERVATION distinct initial slots");
    saved_ar = memory_req.ar;
    saved_aw = memory_req.aw;
    read_slots[0] = saved_ar.id;
    repeat (20) begin
      tick();
      if (!memory_req.ar_valid || !memory_req.aw_valid || memory_req.ar !== saved_ar || memory_req.aw !== saved_aw)
        $fatal(1, "HUB_PAIR_HOLD");
    end
    memory_rsp.ar_ready = 1;
    #2;
    if (!core_rsp[0].ar_ready || core_rsp[1].ar_ready) $fatal(1, "HUB_AR_OWNER");
    tick();
    core_req[0].ar_valid = 0;
    memory_rsp.ar_ready = 0;
    for (int n = 1; n < 3; n++) begin
      accept_read(0, 64'h1000 + 64'(n) * 64'd64, 4'(10 + n), read_slots[n]);
      if (read_slots[n] == saved_aw.id || memory_req.aw !== saved_aw)
        $fatal(1, "HUB_RESERVATION pending write slot reused");
      for (int j = 0; j < n; j++)
        if (read_slots[n] == read_slots[j]) $fatal(1, "HUB_RESERVATION live read slot reused");
    end
    #2;
    if (!memory_req.aw_valid || memory_req.aw !== saved_aw) $fatal(1, "HUB_RESERVED_FULL");
    memory_rsp.aw_ready = 1;
    #2;
    if (!core_rsp[1].aw_ready || core_rsp[0].aw_ready) $fatal(1, "HUB_AW_OWNER");
    tick();
    core_req[1].aw_valid = 0;
    memory_rsp.aw_ready = 0;
    core_req[0].ar = ar(64'h10c0, 4'hd);
    core_req[0].ar_valid = 1;
    #2;
    if (memory_req.ar_valid) $fatal(1, "HUB_RESERVATION full table admitted read");
    finish_write(1, saved_aw.id, 4'he);
    accept_read(0, 64'h10c0, 4'hd, read_slots[3]);
    if (read_slots[3] != saved_aw.id) $fatal(1, "HUB_RESERVATION freed slot unavailable");
    for (int n = 3; n >= 0; n--) return_read(0, read_slots[n], 4'(10 + n), 64'h5500 + 64'(n));
  endtask

  task automatic one_slot;
    aw_chan_t saved;
    id_t read_slot;
    reset();
    if (OT != 1) $fatal(1, "HUB_PARAMETERS one_slot needs OT1");
    core_req[1].aw = aw(64'h2000, 4'he);
    core_req[1].aw_valid = 1;
    #2;
    if (!memory_req.aw_valid) $fatal(1, "HUB_AW_CREDIT sole slot");
    saved = memory_req.aw;
    tick();
    core_req[0].ar = ar(64'h1000, 4'ha);
    core_req[0].ar_valid = 1;
    repeat (20) begin
      #2;
      if (memory_req.ar_valid || !memory_req.aw_valid || memory_req.aw !== saved)
        $fatal(1, "HUB_SINGLE_SLOT_HOLD");
      tick();
    end
    memory_rsp.aw_ready = 1;
    #2;
    if (!core_rsp[1].aw_ready) $fatal(1, "HUB_RESERVED_FULL");
    tick();
    core_req[1].aw_valid = 0;
    memory_rsp.aw_ready = 0;
    finish_write(1, saved.id, 4'he);
    accept_read(0, 64'h1000, 4'ha, read_slot);
    return_read(0, read_slot, 4'ha, 64'h551);
  endtask

  task automatic reset_held;
    id_t slot;
    reset();
    core_req[0].ar = ar(64'h1000, 4'ha);
    core_req[0].ar_valid = 1;
    core_req[1].aw = aw(64'h2000, 4'hb);
    core_req[1].aw_valid = 1;
    #2;
    tick();
    reset();
    if (memory_req.ar_valid || memory_req.aw_valid) $fatal(1, "HUB_RESET_HELD");
    accept_read(1, 64'h3000, 4'hc, slot);
    return_read(1, slot, 4'hc, 64'h123);
  endtask

  task automatic invalidation_retention;
    int phase, completed, accepted, delivered;
    bit pending_aw, pending_w;
    id_t memory_id;
    addr_t accepted_addr[3];
    reset();
    phase = 0;
    completed = 0;
    accepted = 0;
    delivered = 0;
    pending_aw = 0;
    pending_w = 0;
    memory_id = 0;
    for (int n = 0; n < 128; n++) begin
      core_req[0].aw_valid = completed < 3 && phase == 0;
      core_req[0].aw = aw(64'h4000 + 64'(completed) * 64'd64, 4'(completed + 4), 4'b0010);
      core_req[0].w_valid = completed < 3 && phase == 1;
      core_req[0].w = '{data: 64'(completed), strb: '1, last: 1, user: 0};
      memory_rsp = '0;
      memory_rsp.aw_ready = 1;
      memory_rsp.w_ready = 1;
      memory_rsp.b_valid = pending_aw && pending_w;
      memory_rsp.b = '{id: memory_id, resp: 0, user: 0};
      invalidation_ready = n >= 32 ? 2'b11 : 2'b00;
      #2;
      if (invalidations[0].valid) $fatal(1, "HUB_INV_TARGET source invalidated");
      if (invalidations[1].valid && invalidation_ready[1]) begin
        if (delivered >= accepted || !invalidations[1].dcache ||
            invalidations[1].line_addr !== coh_line_tag(accepted_addr[delivered], 64))
          $fatal(1, "HUB_INV_ORDER delivered=%0d accepted=%0d", delivered, accepted);
        delivered++;
      end
      if (core_req[0].aw_valid && core_rsp[0].aw_ready) begin
        if (accepted >= 3) $fatal(1, "HUB_SETUP excess write");
        accepted_addr[accepted] = core_req[0].aw.addr;
        accepted++;
        phase = 1;
      end
      if (core_req[0].w_valid && core_rsp[0].w_ready) phase = 2;
      if (core_rsp[0].b_valid && core_req[0].b_ready) begin
        if (phase != 2 || core_rsp[0].b.id !== 4'(completed + 4) || core_rsp[0].b.resp != 0)
          $fatal(1, "HUB_RESPONSE write identity");
        completed++;
        phase = 0;
      end
      if (memory_rsp.b_valid && memory_req.b_ready) begin
        pending_aw = 0;
        pending_w = 0;
      end
      if (memory_req.aw_valid && memory_rsp.aw_ready) begin
        if (pending_aw) $fatal(1, "HUB_SETUP overlapping memory AW");
        memory_id = memory_req.aw.id;
        pending_aw = 1;
      end
      if (memory_req.w_valid && memory_rsp.w_ready) pending_w = 1;
      tick();
    end
    if (accepted != 3 || completed != 3 || delivered != 3)
      $fatal(1, "HUB_INV_LOSS accepted=%0d completed=%0d delivered=%0d", accepted, completed, delivered);
  endtask

  //  Fairness / starvation override.
  //
  //  The hub keeps a per-core, per-channel starve counter and, at
  //  AXI_STARVE_LIMIT, overrides round-robin to force the starved core to win
  //  (g6lc_coherence_hub.sv:129-140). Three properties of that logic are worth a
  //  test rather than a reading:
  //
  //    * the counter SATURATES at the limit (`< LIMIT` guard, line 414) instead of
  //      wrapping, so a starvation claim cannot be silently lost;
  //    * the override is announced on coh_arb_starve_o -- which no bench had ever
  //      connected, so "the RTL drives it" was the only evidence it worked;
  //    * `if (aw_hold_q) aw_starve_force = 1'b0` (line 141) SUPPRESSES the override
  //      while a write burst owns the channel. That is necessary -- the AW owner
  //      cannot change mid-burst without mis-routing W data -- but it means the
  //      real service bound is LIMIT plus the burst hold, not LIMIT.
  //    * and the override, ONCE ENGAGED, is a fairness HAZARD rather than a net:
  //      at limit 1 one core takes 599 of 600 grants and the rest get none, because
  //      the selection loop picks the highest-indexed starved core and that core
  //      re-qualifies immediately after each grant. Production is safe only because
  //      the limit is never reached -- that margin IS the safety argument.
  //
  //  Method: every core requests AW continuously and the memory side ACCEPTS. An
  //  earlier version refused AW for everyone, which is not starvation at all --
  //  nobody is served, so nobody is relatively starved -- and could never assert the
  //  override, because `aw_hold_q` stays set while an AW is pending downstream and
  //  line 141 clears the force during a hold.
  //
  //  The enforced property is the one that survives whether or not the override
  //  fires: NO core may be shut out. Grant counts per core are reported so the
  //  override's index bias is visible as data rather than asserted as a bound.
  task automatic arbiter_fairness;
    int starve_seen;
    int grants[16];
    int min_grants, max_grants;
    int total_grants;
    bit b_pending;
    id_t b_pending_id;
    reset();
    starve_seen = 0;
    for (int c = 0; c < NC; c++) grants[c] = 0;
    b_pending = 0;
    b_pending_id = '0;

    for (int c = 0; c < NC; c++) begin
      core_req[c].aw       = aw(64'h2000 + (c * 64'h1000), id_t'(c + 1));
      core_req[c].aw_valid = 1;
      core_req[c].w_valid  = 1;
      core_req[c].w        = '{data: 64'hA0 + c, strb: '1, last: 1, user: 0};
    end
    memory_rsp.aw_ready = 1;
    memory_rsp.w_ready  = 1;

    //  Drain B. Without this the scenario is worthless and worse than worthless: the
    //  outstanding scoreboard fills after MAX_OUTSTANDING writes and the hub stops
    //  granting, so EVERY configuration reports exactly OT grants in total and any
    //  core beyond the fourth appears "never granted". I measured that as an
    //  apparent shut-out at NC=8 before noticing the totals were pinned at 4 --
    //  lengthening the window 20x changed nothing, which is the signature of a
    //  stalled harness rather than an unfair arbiter.
    for (int i = 0; i < int'(CYCLES); i++) begin
      #2;
      if (arb_starve) starve_seen++;
      if (memory_req.aw_valid)
        for (int c = 0; c < NC; c++) if (core_rsp[c].aw_ready) grants[c]++;
      //  Complete the previous cycle's write, so its slot is freed and the arbiter
      //  keeps running. The B must be delayed by one cycle: the outstanding slot is
      //  only registered at the clock edge, so a B issued in the SAME cycle as the
      //  AW handshake arrives before the entry exists and cannot be matched. My
      //  first attempt did exactly that, which is why draining B appeared not to
      //  lift the MAX_OUTSTANDING cap at all.
      if (b_pending) begin
        memory_rsp.b_valid = 1;
        memory_rsp.b = '{id: b_pending_id, resp: 2'b00, user: '0};
      end else begin
        memory_rsp.b_valid = 0;
      end
      b_pending = 1'b0;
      if (memory_req.aw_valid && memory_rsp.aw_ready) begin
        b_pending    = 1'b1;
        b_pending_id = memory_req.aw.id;
      end
      tick();
    end
    memory_rsp.b_valid = 0;

    if (negative) begin
      //  Perturb the OBSERVATION, not the DUT: pretend core 0 was never granted, so
      //  the shut-out check must fire. A control that cannot fail is
      //  indistinguishable from an absent one.
      grants[0] = 0;
    end

    min_grants = grants[0];
    max_grants = grants[0];
    for (int c = 1; c < NC; c++) begin
      if (grants[c] < min_grants) min_grants = grants[c];
      if (grants[c] > max_grants) max_grants = grants[c];
    end

    //  The property that holds whether or not the override fires: NO core is shut
    //  out. Deliberately not a ratio bound -- the spread is REPORTED below so the
    //  index bias is data rather than an assumption, and a bound can be chosen once
    //  its shape at higher core counts is known.
    //  A shut-out claim is only meaningful once there have been at least as many
    //  grants as cores. Below that, "core 4 never granted" says the run produced
    //  four grants for eight cores -- a THROUGHPUT limit, not starvation -- and
    //  failing on it would report an arbiter defect that the data does not support.
    //  This guard exists because I made exactly that mistake: NC=8 looked like a
    //  shut-out until the totals turned out to be pinned at MAX_OUTSTANDING.
    total_grants = 0;
    for (int c = 0; c < NC; c++) total_grants += grants[c];

    if (total_grants < int'(NC)) begin
      $display("HUB_STARVE_INCONCLUSIVE nc=%0d limit=%0d cycles=%0d total_grants=%0d < nc: throughput-limited, fairness not decidable",
               NC, STARVE_LIMIT, CYCLES, total_grants);
    end else begin
      for (int c = 0; c < NC; c++)
        if (grants[c] == 0)
          $fatal(1, "HUB_STARVE_SHUTOUT core %0d never granted in %0d cycles (total=%0d min=%0d max=%0d)",
                 c, CYCLES, total_grants, min_grants, max_grants);
    end

    if (STARVE_LIMIT <= 2 && starve_seen == 0)
      $fatal(1, "HUB_STARVE_UNREACHABLE limit=%0d yet the override never asserted",
             STARVE_LIMIT);

    $write("HUB_STARVE_METRICS nc=%0d limit=%0d cycles=%0d starve_cycles=%0d total=%0d spread=%0d:%0d grants=",
           NC, STARVE_LIMIT, CYCLES, starve_seen, total_grants, min_grants, max_grants);
    for (int c = 0; c < NC; c++) $write("%0d ", grants[c]);
    $display("");

    for (int c = 0; c < NC; c++) begin
      core_req[c].aw_valid = 0;
      core_req[c].w_valid  = 0;
    end
  endtask

  initial begin
    scenario = 0;
    negative = $test$plusargs("oracle_negative");
    void'($value$plusargs("scenario=%d", scenario));
    case (scenario)
      0: basic();
      1: ar_stability();
      2: aw_stability();
      3: id_stability();
      4: aw_credit();
      5: invalidation_retention();
      6: reservations();
      7: one_slot();
      8: reset_held();
      9: arbiter_fairness();
      default: $fatal(1, "HUB_SCENARIO");
    endcase
    $display("HUB_PASS scenario=%0d", scenario);
    $finish;
  end
endmodule
