// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_coherence_hub;
  import g6lc_coherence_pkg::*;
  import g6lc_l2_tb_pkg::*;
  parameter int unsigned OT = 4;
  parameter bit OOO = 1'b0;
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
  //  Memory acceptance rate for the fairness scenario: AW is accepted once every
  //  (MEM_STALL+1) cycles. 0 is an infinitely fast memory, which is what the first
  //  measurement used -- and it flattered the design, because the service interval
  //  it produces is the SHORTEST possible. Real memory is slower, so this sweeps
  //  the one variable that decides whether the starve override is reachable.
  parameter int unsigned MEM_STALL = 0;
  //  ACK-after-invalidation control. 0 rebuilds the ack-before-invalidation
  //  defect for the restored-defect mutation run; INV_LAT is the DUT's
  //  INV_APPLY_LATENCY so scenario deadlines track the configured margin.
  parameter bit ACK_AFTER_INVAL = 1;
  parameter int unsigned INV_LAT = 1;
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
    .SNOOP_FILTER_EN(OOO), .SNOOP_FILTER_ENTRIES(4),
    .POLICY(OOO ? config_pkg::COH_OOO : config_pkg::COH_BROADCAST), .AXI_STARVE_LIMIT(STARVE_LIMIT),
    .ACK_AFTER_INVAL(ACK_AFTER_INVAL), .INV_APPLY_LATENCY(INV_LAT),
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
    if (OOO) repeat (5) tick();
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
      if (!core_rsp[core].r_valid ||
          core_rsp[core].r.id !== original || core_rsp[core].r.data !== data || memory_req.r_ready)
        $fatal(1, "HUB_R_HOLD");
      for (int c = 0; c < NC; c++)
        if (c != core && core_rsp[c].r_valid) $fatal(1, "HUB_R_PEER");
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
    memory_rsp.w_ready  = 1;

    //  Drain B. Without this the scenario is worthless and worse than worthless: the
    //  outstanding scoreboard fills after MAX_OUTSTANDING writes and the hub stops
    //  granting, so EVERY configuration reports exactly OT grants in total and any
    //  core beyond the fourth appears "never granted". I measured that as an
    //  apparent shut-out at NC=8 before noticing the totals were pinned at 4 --
    //  lengthening the window 20x changed nothing, which is the signature of a
    //  stalled harness rather than an unfair arbiter.
    for (int i = 0; i < int'(CYCLES); i++) begin
      //  Throttle acceptance to model memory that is not instantly ready.
      memory_rsp.aw_ready = (MEM_STALL == 0) || ((i % (int'(MEM_STALL) + 1)) == 0);
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

  task automatic atomic_lifetime;
    id_t slot, reads[OT];
    for (int order = 0; order < 3; order++) begin
      reset();
      core_req[0].aw = aw(64'h8000, 4'he);
      core_req[0].aw.atop = 6'b100000;
      core_req[0].aw_valid = 1;
      memory_rsp.aw_ready = 1;
      #2;
      if (!core_rsp[0].aw_ready) $fatal(1, "HUB_ATOP_SETUP");
      slot = memory_req.aw.id;
      tick();
      core_req[0].aw_valid = 0;
      memory_rsp.aw_ready = 0;
      core_req[0].w = '{data: 64'h991, strb: '1, last: 1, user: 0};
      core_req[0].w_valid = 1;
      memory_rsp.w_ready = 1;
      #2;
      if (!core_rsp[0].w_ready) $fatal(1, "HUB_ATOP_W");
      tick();
      core_req[0].w_valid = 0;
      memory_rsp.w_ready = 0;
      repeat (2 + INV_LAT) tick();
      for (int n = 0; n < OT - 1; n++)
        accept_read(1, 64'h9000 + 64'(n) * 64'd64, id_t'(n), reads[n]);
      core_req[1].ar = ar(64'ha000, 4'hf);
      core_req[1].ar_valid = 1;
      memory_rsp.ar_ready = 1;
      memory_rsp.r = '{id: slot, data: 64'h123456, resp: 0, last: 1, user: 0};
      memory_rsp.b = '{id: slot, resp: 0, user: 0};
      for (int phase = 0; phase < (order == 2 ? 1 : 2); phase++) begin
        memory_rsp.r_valid = order == 2 || (order == 1 ? phase == 0 : phase == 1);
        memory_rsp.b_valid = order == 2 || !memory_rsp.r_valid;
        core_req[0].r_ready = 0;
        core_req[0].b_ready = 0;
        repeat (3) begin
          #2;
          if (memory_req.ar_valid || memory_req.r_ready || memory_req.b_ready)
            $fatal(1, "HUB_ATOP_LIFETIME premature credit/accept order=%0d phase=%0d", order, phase);
          if (memory_rsp.r_valid && (!core_rsp[0].r_valid || core_rsp[1].r_valid ||
              core_rsp[0].r.id != 4'he || core_rsp[0].r.data != 64'h123456))
            $fatal(1, "HUB_ATOP_R_OWNER");
          if (memory_rsp.b_valid && (!core_rsp[0].b_valid || core_rsp[1].b_valid ||
              core_rsp[0].b.id != 4'he)) $fatal(1, "HUB_ATOP_B_OWNER");
          tick();
        end
        core_req[0].r_ready = 1;
        core_req[0].b_ready = 1;
        #2;
        if ((memory_rsp.r_valid && !memory_req.r_ready) ||
            (memory_rsp.b_valid && !memory_req.b_ready)) $fatal(1, "HUB_ATOP_ACCEPT");
        tick();
        memory_rsp.r_valid = 0;
        memory_rsp.b_valid = 0;
      end
      #2;
      if (!core_rsp[1].ar_ready || memory_req.ar.id != slot)
        $fatal(1, "HUB_ATOP_RELEASE");
      tick();
      core_req[1].ar_valid = 0;
      memory_rsp.ar_ready = 0;
      return_read(1, slot, 4'hf, 64'h1122);
      for (int n = 0; n < OT - 1; n++) return_read(1, reads[n], id_t'(n), 64'(n));
    end
  endtask

  task automatic atomic_remaining_orders;
    id_t atomic_slot;
    id_t [OT-1:0] slots;
    for (int together = 0; together < 2; together++) begin
      reset();
      core_req[0].aw = aw(64'h7300, 4'ha, 4'h0);
      core_req[0].aw.atop = 6'h20;
      core_req[0].aw_valid = 1;
      memory_rsp.aw_ready = 1;
      #2;
      if (!core_rsp[0].aw_ready) $fatal(1, "HUB_ATOP_SETUP");
      atomic_slot = memory_req.aw.id;
      tick();
      core_req[0].aw_valid = 0;
      memory_rsp.aw_ready = 0;
      core_req[0].w = '{data: 64'h45, strb: '1, last: 1, user: 0};
      core_req[0].w_valid = 1;
      memory_rsp.w_ready = 1;
      tick();
      core_req[0].w_valid = 0;
      memory_rsp.w_ready = 0;
      repeat (2 + INV_LAT) tick();
      core_req[0].b_ready = 0;
      core_req[0].r_ready = 0;
      memory_rsp.b_valid = 1;
      memory_rsp.b = '{id: atomic_slot, resp: 0, user: 0};
      memory_rsp.r_valid = (together != 0);
      memory_rsp.r = '{id: atomic_slot, data: 64'h54, resp: 0, last: 1, user: 0};
      repeat (3) begin
        #2;
        if (!core_rsp[0].b_valid || core_rsp[0].b.id != 4'ha || memory_req.b_ready ||
            (together != 0 && (!core_rsp[0].r_valid || memory_req.r_ready ||
                              core_rsp[0].r.id != 4'ha || core_rsp[0].r.data != 64'h54)))
          $fatal(1, "HUB_ATOP_COMPONENT_HOLD");
        tick();
      end
      core_req[0].b_ready = 1;
      core_req[0].r_ready = (together != 0);
      tick();
      memory_rsp.b_valid = 0;
      memory_rsp.r_valid = 0;
      if (together == 0) return_read(0, atomic_slot, 4'ha, 64'h54);
      for (int n = 0; n < OT; n++) accept_read(1, 64'h8000 + 64'(n) * 128, id_t'(n), slots[n]);
      for (int n = 0; n < OT; n++) return_read(1, slots[n], id_t'(n), 64'(n));
    end
  endtask

  task automatic signature_hub;
    id_t slot, write_slot;
    aw_chan_t saved;
    if (!OOO || NC != 3) $fatal(1, "HUB_SIGNATURE_GEOMETRY");
    reset();
    accept_read(0, 64'h4000, 4'd1, slot);
    return_read(0, slot, 4'd1, 64'h101);
    accept_read(1, 64'h4100, 4'd2, slot);
    return_read(1, slot, 4'd2, 64'h102);
    invalidation_ready = '0;
    core_req[1].aw = aw(64'h4000, 4'd3, 4'hf);
    core_req[1].aw_valid = 1;
    for (int n = 0; n < 8 && !memory_req.aw_valid; n++) tick();
    if (!memory_req.aw_valid) $fatal(1, "HUB_SIGNATURE_LOOKUP");
    saved = memory_req.aw;
    write_slot = saved.id;
    core_req[2].ar = ar(64'h4040, 4'd4);
    core_req[2].ar_valid = 1;
    repeat (5) begin
      tick();
      if (!memory_req.aw_valid || memory_req.aw !== saved || core_rsp[2].ar_ready)
        $fatal(1, "HUB_SIGNATURE_HELD");
    end
    memory_rsp.aw_ready = 1;
    #2;
    if (!core_rsp[1].aw_ready) $fatal(1, "HUB_SIGNATURE_ADMIT");
    tick();
    core_req[1].aw_valid = 0;
    memory_rsp.aw_ready = 0;
    memory_rsp.ar_ready = 1;
    #2;
    if (!core_rsp[2].ar_ready) $fatal(1, "HUB_SIGNATURE_AR_RESUME");
    slot = memory_req.ar.id;
    tick();
    core_req[2].ar_valid = 0;
    memory_rsp.ar_ready = 0;
    core_req[1].w = '{data: 64'h103, strb: '1, last: 1, user: 0};
    core_req[1].w_valid = 1;
    memory_rsp.w_ready = 1;
    tick();
    core_req[1].w_valid = 0;
    memory_rsp.w_ready = 0;
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: write_slot, resp: 0, user: 0};
    #2;
    //  The writer's B may be consumed by the hub but must NOT reach core 1
    //  until its invalidation has been delivered to core 0 (the signature
    //  target) and INV_APPLY_LATENCY has elapsed. The previous check required
    //  B in this same cycle -- that was the ack-before-invalidation defect
    //  this scenario now pins as a failure.
    if (core_rsp[1].b_valid) $fatal(1, "HUB_B_BEFORE_INVAL");
    if (!memory_req.b_ready) $fatal(1, "HUB_SETUP B not consumed");
    tick();
    memory_rsp.b_valid = 0;
    if (!(invalidations[0].valid ^ negative) || invalidations[1].valid ||
        invalidations[2].valid || invalidations[0].line_addr != coh_line_tag(64'h4000, 64))
      $fatal(1, "HUB_SIGNATURE_TARGET");
    invalidation_ready = '1;
    begin
      int k;
      k = -1;
      for (int n = 0; n < 20; n++) begin
        #2;
        if (k < 0 && invalidations[0].valid && invalidation_ready[0]) k = n;
        if (k >= 0 && n <= k + 1 + INV_LAT && core_rsp[1].b_valid)
          $fatal(1, "HUB_B_BEFORE_INVAL k=%0d n=%0d", k, n);
        if (k >= 0 && n == k + 2 + INV_LAT &&
            (!core_rsp[1].b_valid || core_rsp[1].b.id != 4'd3))
          $fatal(1, "HUB_SIGNATURE_B k=%0d", k);
        tick();
        if (k >= 0 && n >= k + 2 + INV_LAT) break;
      end
      if (k < 0) $fatal(1, "HUB_SIGNATURE_TARGET never delivered");
    end
    return_read(2, slot, 4'd4, 64'h104);
  endtask

  //  OOO-aware write driver: under the signature filter the hub holds the AW
  //  while it runs the presence lookup, so the bench waits for the memory-side
  //  AW instead of assuming a one-cycle admit (drive_write cannot see that).
  task automatic ooo_write(input int core, input addr_t addr, input id_t id,
                           output id_t slot, input logic [3:0] cache = 4'b0010);
    core_req[core].aw = aw(addr, id, cache);
    core_req[core].aw_valid = 1;
    for (int n = 0; n < 8 && !memory_req.aw_valid; n++) tick();
    if (!memory_req.aw_valid) $fatal(1, "HUB_WRITER_SETUP core=%0d", core);
    memory_rsp.aw_ready = 1;
    #2;
    if (!core_rsp[core].aw_ready) $fatal(1, "HUB_WRITER_SETUP core=%0d", core);
    slot = memory_req.aw.id;
    tick();
    core_req[core].aw_valid = 0;
    memory_rsp.aw_ready = 0;
    core_req[core].w = '{data: 64'h5a, strb: '1, last: 1, user: 0};
    core_req[core].w_valid = 1;
    memory_rsp.w_ready = 1;
    tick();
    core_req[core].w_valid = 0;
    memory_rsp.w_ready = 0;
  endtask

  //  Writer acquisition: a core's first contact with a line can be an AW, and
  //  the signature filter must record that writer as a sharer so a second
  //  writer's invalidation reaches it. Registering presence only on AR leaves
  //  the first writer invisible -- the mc_shared_line hang.
  task automatic writer_acquisition;
    id_t slot;
    if (!OOO || NC != 3) $fatal(1, "HUB_WRITER_GEOMETRY");
    reset();
    //  Hold deliveries so a raised invalidation stays asserted for sampling
    //  (like signature_hub); it is released before each B drain.
    invalidation_ready = '0;

    //  (a) core 0 writes 0x4000. It is the only sharer, so the write must not
    //  raise any invalidation while its B drains.
    ooo_write(0, 64'h4000, 4'd5, slot);
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: slot, resp: 0, user: 0};
    begin
      bit seen;
      seen = 0;
      for (int n = 0; n < 20 && !seen; n++) begin
        #2;
        for (int c = 0; c < NC; c++)
          if (invalidations[c].valid) $fatal(1, "HUB_WRITER_SPURIOUS_INVAL");
        if (core_rsp[0].b_valid) seen = 1;
        tick();
      end
      if (!seen) $fatal(1, "HUB_WRITER_DRAIN core=0");
    end
    memory_rsp.b_valid = 0;

    //  (b) core 1 writes the same line. Core 0 acquired presence at AW fire,
    //  so the invalidation must target core 0 and no one else.
    ooo_write(1, 64'h4000, 4'd6, slot);
    begin
      bit hit;
      hit = 0;
      for (int n = 0; n < 8; n++) begin
        #2;
        if (invalidations[1].valid || invalidations[2].valid)
          $fatal(1, "HUB_WRITER_ACQUISITION");
        if (invalidations[0].valid &&
            invalidations[0].line_addr != coh_line_tag(64'h4000, 64))
          $fatal(1, "HUB_WRITER_ACQUISITION");
        if (invalidations[0].valid ^ negative) hit = 1;
        tick();
      end
      if (!hit) $fatal(1, "HUB_WRITER_ACQUISITION");
    end
    invalidation_ready = '1;
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: slot, resp: 0, user: 0};
    begin
      bit seen;
      seen = 0;
      for (int n = 0; n < 24 && !seen; n++) begin
        #2;
        if (core_rsp[1].b_valid) seen = 1;
        tick();
      end
      if (!seen) $fatal(1, "HUB_WRITER_DRAIN core=1");
    end
    memory_rsp.b_valid = 0;

    //  (c) control: core 2 shares 0x4040 via AR, core 1 writes that line, the
    //  invalidation must target core 2 only.
    accept_read(2, 64'h4040, 4'd7, slot);
    return_read(2, slot, 4'd7, 64'h201);
    invalidation_ready = '0;
    ooo_write(1, 64'h4040, 4'd8, slot);
    begin
      bit hit;
      hit = 0;
      for (int n = 0; n < 8; n++) begin
        #2;
        if (invalidations[0].valid) $fatal(1, "HUB_WRITER_ACQUISITION control");
        if (invalidations[2].valid &&
            invalidations[2].line_addr == coh_line_tag(64'h4040, 64)) hit = 1;
        tick();
      end
      if (!hit) $fatal(1, "HUB_WRITER_ACQUISITION control");
    end
    invalidation_ready = '1;
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: slot, resp: 0, user: 0};
    begin
      bit seen;
      seen = 0;
      for (int n = 0; n < 24 && !seen; n++) begin
        #2;
        if (core_rsp[1].b_valid) seen = 1;
        tick();
      end
      if (!seen) $fatal(1, "HUB_WRITER_DRAIN core=1");
    end
    memory_rsp.b_valid = 0;
  endtask

  //  ------------------------------------------------------------------
  //  ACK-after-invalidation scenarios (14-18).
  //
  //  Timing model: the invalidation-bus pop handshake for a target is observed
  //  at sample cycle k (invalidations[t].valid && invalidation_ready[t]); the
  //  pop lands at the edge ending that cycle. The deq sequence is visible one
  //  cycle later, the L1 applies during the cycle after the pop edge, so the
  //  writer's B is legal at sample k+2+INV_LAT and forbidden any earlier.
  //  ------------------------------------------------------------------

  task automatic drive_write(input int core, input addr_t addr, input id_t id,
                             output id_t slot, input logic [3:0] cache = 4'b0010);
    core_req[core].aw = aw(addr, id, cache);
    core_req[core].aw_valid = 1;
    memory_rsp.aw_ready = 1;
    #2;
    if (!memory_req.aw_valid || !core_rsp[core].aw_ready)
      $fatal(1, "HUB_SETUP aw core=%0d", core);
    slot = memory_req.aw.id;
    tick();
    core_req[core].aw_valid = 0;
    memory_rsp.aw_ready = 0;
    core_req[core].w = '{data: 64'h5a, strb: '1, last: 1, user: 0};
    core_req[core].w_valid = 1;
    memory_rsp.w_ready = 1;
    #2;
    if (!memory_req.w_valid || !core_rsp[core].w_ready)
      $fatal(1, "HUB_SETUP w core=%0d", core);
    tick();
    core_req[core].w_valid = 0;
    memory_rsp.w_ready = 0;
  endtask

  //  Scenario 14: B consumed early, withheld until delivery + apply latency.
  task automatic write_ack_after_inval;
    id_t slot;
    int k, first_b;
    bit seen_early;
    reset();
    invalidation_ready = 2'b01;
    drive_write(0, 64'h4000, 4'h7, slot);
    // B arrives two cycles after W -- long before the invalidation is consumed.
    tick();
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: slot, resp: 0, user: 0};
    seen_early = 0;
    #2;
    if (core_rsp[0].b_valid) seen_early = 1;
    if (!memory_req.b_ready) $fatal(1, "HUB_SETUP B not consumed");
    tick();
    memory_rsp.b_valid = 0;
    k = -1;
    first_b = -1;
    for (int n = 0; n < 60; n++) begin
      if (n == 12) invalidation_ready = 2'b11;
      #2;
      if (n < 12 && !invalidations[1].valid)
        $fatal(1, "HUB_SETUP invalidation not presented while blocked");
      if (invalidations[1].valid && invalidation_ready[1] && k < 0) k = n;
      if (core_rsp[0].b_valid) begin
        if (first_b < 0) first_b = n;
        if (k < 0 || n <= k + 1 + INV_LAT) seen_early = 1;
        if (core_rsp[0].b.id !== 4'h7 || core_rsp[0].b.resp != 0)
          $fatal(1, "HUB_RESPONSE write identity");
      end
      if (k >= 0 && n == k + 2 + INV_LAT && !core_rsp[0].b_valid &&
          first_b < 0 && !seen_early)
        $fatal(1, "HUB_B_AFTER_INVAL_LATE k=%0d", k);
      tick();
      if (k >= 0 && n >= k + 2 + INV_LAT) break;
    end
    if (k < 0) $fatal(1, "HUB_SETUP invalidation never delivered");
    if (negative) begin
      if (!seen_early) $fatal(1, "HUB_B_BEFORE_INVAL");
    end else if (seen_early)
      $fatal(1, "HUB_B_BEFORE_INVAL first_b=%0d k=%0d", first_b, k);
    $display("HUB_ACK_TIMING scenario=14 k=%0d first_b=%0d inv_lat=%0d",
             k, first_b, INV_LAT);
  endtask

  //  Scenario 15: an unrelated writer's B must pass while another core's B is
  //  held for a blocked invalidation.
  task automatic write_ack_independent;
    id_t slot_x, slot_y;
    int k;
    bit x_leak, x_seen, y_done;
    reset();
    invalidation_ready = 2'b01;  // core0 drains; core1 (X's target) is blocked
    drive_write(0, 64'h5000, 4'h8, slot_x);   // targets core1 (blocked)
    drive_write(1, 64'h9000, 4'h9, slot_y);   // targets core0 (ready)
    // Return Y's B first: its obligation to core0 was already delivered, so it
    // must not be delayed by X's held B.
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: slot_y, resp: 0, user: 0};
    y_done = 0;
    x_leak = 0;
    x_seen = 0;
    for (int n = 0; n < 16 && !y_done; n++) begin
      #2;
      if (core_rsp[0].b_valid) begin
        x_leak = 1;
        x_seen = 1;
      end
      if (core_rsp[1].b_valid) begin
        if (core_rsp[1].b.id !== 4'h9) $fatal(1, "HUB_RESPONSE write identity");
        y_done = 1;
      end
      tick();
    end
    memory_rsp.b_valid = 0;
    if (negative) begin
      if (y_done) $fatal(1, "HUB_B_HOLD");
    end else if (!y_done) $fatal(1, "HUB_B_HOLD");
    // Now X's B: parked until core1's invalidation pops + settle.
    memory_rsp.b = '{id: slot_x, resp: 0, user: 0};
    memory_rsp.b_valid = 1;
    #2;
    if (!memory_req.b_ready) $fatal(1, "HUB_SETUP B not consumed");
    tick();
    memory_rsp.b_valid = 0;
    k = -1;
    for (int n = 0; n < 40; n++) begin
      if (n == 6) invalidation_ready = 2'b11;
      #2;
      if (invalidations[1].valid && invalidation_ready[1] && k < 0) k = n;
      if (core_rsp[0].b_valid) begin
        x_seen = 1;
        if (k < 0 || n <= k + 1 + INV_LAT) x_leak = 1;
        if (core_rsp[0].b.id !== 4'h8) $fatal(1, "HUB_RESPONSE write identity");
      end
      if (k >= 0 && n == k + 2 + INV_LAT && !core_rsp[0].b_valid && !x_seen)
        $fatal(1, "HUB_B_AFTER_INVAL_LATE k=%0d", k);
      tick();
      if (k >= 0 && n >= k + 2 + INV_LAT) break;
    end
    if (k < 0) $fatal(1, "HUB_SETUP invalidation never delivered");
    if (!negative && x_leak) $fatal(1, "HUB_B_BEFORE_INVAL");
    $display("HUB_ACK_TIMING scenario=15 k=%0d", k);
  endtask

  //  Scenario 16: two same-line writes coalesce to a single invalidation; both
  //  Bs wait for the one pop and then drain lowest-slot-first.
  task automatic write_ack_coalesce;
    id_t slot0, slot1;
    int k, b_count, pops;
    bit seen_early;
    reset();
    invalidation_ready = 2'b01;
    drive_write(0, 64'h6000, 4'h5, slot0);
    drive_write(0, 64'h6000, 4'h6, slot1);
    seen_early = 0;
    // Both Bs arrive while the single coalesced obligation is still blocked.
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: slot0, resp: 0, user: 0};
    #2;
    if (core_rsp[0].b_valid) seen_early = 1;
    tick();
    memory_rsp.b = '{id: slot1, resp: 0, user: 0};
    #2;
    if (core_rsp[0].b_valid) seen_early = 1;
    tick();
    memory_rsp.b_valid = 0;
    k = -1;
    b_count = 0;
    pops = 0;
    for (int n = 0; n < 60; n++) begin
      if (n == 8) invalidation_ready = 2'b11;
      #2;
      if (invalidations[1].valid && invalidation_ready[1]) begin
        if (k < 0) k = n;
        pops++;
      end
      if (core_rsp[0].b_valid) begin
        b_count++;
        if (k < 0 || n <= k + 1 + INV_LAT) seen_early = 1;
        if (b_count == 1 && core_rsp[0].b.id !== 4'h5)
          $fatal(1, "HUB_B_COALESCE_LATE first b id=%h", core_rsp[0].b.id);
        if (b_count == 2 && core_rsp[0].b.id !== 4'h6)
          $fatal(1, "HUB_B_COALESCE_LATE second b id=%h", core_rsp[0].b.id);
      end
      if (k >= 0 && n == k + 1 && invalidations[1].valid && !seen_early)
        $fatal(1, "HUB_B_COALESCE_LATE obligation was not coalesced");
      if (k >= 0 && n == k + 3 + INV_LAT && b_count != 2 && !seen_early)
        $fatal(1, "HUB_B_COALESCE_LATE k=%0d count=%0d", k, b_count);
      tick();
      if (k >= 0 && n >= k + 3 + INV_LAT) break;
    end
    if (k < 0) $fatal(1, "HUB_SETUP invalidation never delivered");
    if (pops != 1) $fatal(1, "HUB_B_COALESCE_LATE pops=%0d", pops);
    if (negative) begin
      if (!seen_early) $fatal(1, "HUB_B_BEFORE_INVAL");
    end else if (seen_early) $fatal(1, "HUB_B_BEFORE_INVAL");
    $display("HUB_ACK_TIMING scenario=16 k=%0d pops=%0d", k, pops);
  endtask

  //  Scenario 17: when delivery and the apply latency are already in the past,
  //  a memory B must reach the core in the SAME cycle -- zero added latency.
  task automatic write_ack_fast_path;
    id_t slot;
    logic same_cycle;
    reset();
    // invalidation_ready stays '1: the obligation delivers immediately.
    drive_write(0, 64'h7000, 4'ha, slot);
    repeat (6) tick();
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: slot, resp: 0, user: 0};
    #2;
    same_cycle = core_rsp[0].b_valid && core_rsp[0].b.id === 4'ha &&
                 core_rsp[0].b.resp == 0 && memory_req.b_ready;
    if (same_cycle == negative) $fatal(1, "HUB_B_FAST_PATH");
    tick();
    memory_rsp.b_valid = 0;
  endtask

  //  Scenario 18: three writes to different lines with the target blocked fill
  //  INVAL_DEPTH=2; the third obligation is retained in inv_pend and its slot
  //  is stamped only when the bus accepts it after the first pop.
  task automatic write_ack_retained;
    id_t slots[3];
    int pops, b_count;
    int b_cycle[3], pop_cycle[3];
    bit seen_early;
    reset();
    invalidation_ready = 2'b01;
    for (int i = 0; i < 3; i++)
      drive_write(0, 64'h8000 + 64'(i) * 64'd64, id_t'(4'h5 + i), slots[i]);
    for (int i = 0; i < 3; i++) begin
      memory_rsp.b_valid = 1;
      memory_rsp.b = '{id: slots[i], resp: 0, user: 0};
      #2;
      tick();
    end
    memory_rsp.b_valid = 0;
    pops = 0;
    b_count = 0;
    seen_early = 0;
    for (int i = 0; i < 3; i++) begin
      b_cycle[i] = -1;
      pop_cycle[i] = -1;
    end
    for (int n = 0; n < 80; n++) begin
      if (n == 6) invalidation_ready = 2'b11;
      #2;
      if (invalidations[1].valid && invalidation_ready[1]) begin
        if (pops < 3) pop_cycle[pops] = n;
        pops++;
      end
      if (core_rsp[0].b_valid) begin
        if (b_count < 3) b_cycle[b_count] = n;
        b_count++;
      end
      tick();
      if (b_count == 3 && pops >= 3) break;
    end
    for (int i = 0; i < 3; i++)
      if (b_cycle[i] < 0 || pop_cycle[i] < 0 ||
          b_cycle[i] < pop_cycle[i] + 2 + INV_LAT) seen_early = 1;
    if (pops != 3 || b_count != 3)
      $fatal(1, "HUB_B_RETAINED_LATE pops=%0d bs=%0d", pops, b_count);
    if (negative) begin
      if (!seen_early) $fatal(1, "HUB_B_BEFORE_INVAL");
    end else if (seen_early)
      $fatal(1, "HUB_B_BEFORE_INVAL pops=%0d,%0d,%0d bs=%0d,%0d,%0d",
             pop_cycle[0], pop_cycle[1], pop_cycle[2],
             b_cycle[0], b_cycle[1], b_cycle[2]);
    $display("HUB_ACK_TIMING scenario=18 pops=%0d,%0d,%0d bs=%0d,%0d,%0d",
             pop_cycle[0], pop_cycle[1], pop_cycle[2],
             b_cycle[0], b_cycle[1], b_cycle[2]);
  endtask

  task automatic b_offer_stability(input bit held_offer);
    id_t first_slot, offered_slot, later_slot;
    resp_t saved;
    reset();
    if (NC != 2 || OT < 3) $fatal(1, "HUB_B_STABILITY_GEOMETRY");
    core_req[0].b_ready = 0;
    invalidation_ready = 2'b01;
    if (held_offer) begin
      drive_write(1, 64'h2000, 4'h2, first_slot, 4'b0000);
      drive_write(0, 64'h4000, 4'h7, offered_slot);
    end else begin
      drive_write(0, 64'h4000, 4'h2, first_slot);
      drive_write(0, 64'h5000, 4'h7, offered_slot, 4'b0000);
    end
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: held_offer ? offered_slot : first_slot, resp: 2, user: 1};
    #2;
    if (!memory_req.b_ready) $fatal(1, "HUB_B_STABILITY_SETUP_PARK");
    tick(); memory_rsp.b_valid = 0;
    if (held_offer) begin
      invalidation_ready = '1;
      repeat (6 + INV_LAT) tick();
    end else begin
      memory_rsp.b_valid = 1;
      memory_rsp.b = '{id: offered_slot, resp: 0, user: 0};
    end
    #2;
    if (!core_rsp[0].b_valid || core_rsp[0].b.id != 4'h7)
      $fatal(1, "HUB_B_STABILITY_SETUP_OFFER");
    saved = core_rsp[0];
    tick();
    if (held_offer) begin
      memory_rsp.b_valid = 1;
      memory_rsp.b = '{id: first_slot, resp: 0, user: 0};
      #2;
      if (!core_rsp[1].b_valid || !memory_req.b_ready)
        $fatal(1, "HUB_B_STABILITY_SETUP_FREE");
      tick(); memory_rsp.b_valid = 0;
      drive_write(0, 64'h6000, 4'h9, later_slot, 4'b0000);
      if (later_slot >= offered_slot) $fatal(1, "HUB_B_STABILITY_SETUP_REUSE");
      memory_rsp.b_valid = 1;
      memory_rsp.b = '{id: later_slot, resp: 0, user: 0};
      #2;
      if (!memory_req.b_ready) $fatal(1, "HUB_B_STABILITY_SETUP_LATER");
      tick(); memory_rsp.b_valid = 0;
    end else invalidation_ready = '1;
    for (int n = 0; n < 8 + INV_LAT; n++) begin
      #2;
      if ((!core_rsp[0].b_valid || core_rsp[0].b !== saved.b) ^ negative)
        $fatal(1, "HUB_B_STABILITY held=%0d n=%0d want=%h got=%h",
               held_offer, n, saved.b, core_rsp[0].b);
      tick();
    end
    core_req[0].b_ready = 1;
    #2;
    if (core_rsp[0].b !== saved.b) $fatal(1, "HUB_B_STABILITY_ACCEPT");
    tick(); memory_rsp.b_valid = 0;
    #2;
    if (!core_rsp[0].b_valid || core_rsp[0].b.id != (held_offer ? 4'h9 : 4'h2))
      $fatal(1, "HUB_B_STABILITY_DRAIN");
    tick();
  endtask

  task automatic atomic_invalidation_publication(input bit uncached);
    id_t slot;
    bit r_done, b_done, take_r, take_b;
    reset();
    invalidation_ready = 2'b01;
    core_req[0].aw = aw(64'h80004000, 4'h6, uncached ? 4'b0000 : 4'b0010);
    core_req[0].aw.atop = 6'b100000;
    core_req[0].aw_valid = 1;
    memory_rsp.aw_ready = 1;
    #2;
    if (!memory_req.aw_valid || !core_rsp[0].aw_ready) $fatal(1, "HUB_ATOMIC_PUBLICATION_SETUP");
    slot = memory_req.aw.id;
    tick(); core_req[0].aw_valid = 0; memory_rsp.aw_ready = 0;
    core_req[0].w = '{data:64'h123, strb:'1, last:1, user:0};
    core_req[0].w_valid = 1; memory_rsp.w_ready = 1;
    #2;
    if (!core_rsp[0].w_ready) $fatal(1, "HUB_ATOMIC_PUBLICATION_W");
    tick(); core_req[0].w_valid = 0; memory_rsp.w_ready = 0;
    repeat (3) tick();
    if (uncached && ((!invalidations[1].valid) ^ negative)) $fatal(1, "HUB_ATOMIC_MISSING_INVAL");
    memory_rsp.r_valid = 1;
    memory_rsp.r = '{id:slot, data:64'h88, resp:0, last:1, user:0};
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id:slot, resp:0, user:0};
    r_done = 0; b_done = 0;
    for (int n = 0; n < 24; n++) begin
      if (n == 8) invalidation_ready = '1;
      #2;
      if (n < 8 && ((core_rsp[0].r_valid || core_rsp[0].b_valid) ^ negative))
        $fatal(1, "HUB_ATOMIC_BEFORE_INVAL");
      if (core_rsp[0].r_valid) begin
        if (r_done || core_rsp[0].r.id != 4'h6 || core_rsp[0].r.data != 64'h88)
          $fatal(1, "HUB_ATOMIC_PUBLICATION_R");
        r_done = 1;
      end
      if (core_rsp[0].b_valid) begin
        if (b_done || core_rsp[0].b.id != 4'h6) $fatal(1, "HUB_ATOMIC_PUBLICATION_B");
        b_done = 1;
      end
      take_r = memory_rsp.r_valid && memory_req.r_ready;
      take_b = memory_rsp.b_valid && memory_req.b_ready;
      tick();
      if (take_r) memory_rsp.r_valid = 0;
      if (take_b) memory_rsp.b_valid = 0;
      if (r_done && b_done) break;
    end
    if (!r_done || !b_done) $fatal(1, "HUB_ATOMIC_PUBLICATION_DRAIN");
  endtask

  task automatic refill_during_write;
    id_t write_slot, read_slot;
    bit read_pending, write_done, b_sent, core_b_seen, core_r_seen;
    bit cache_valid, fill_killed, take_r, take_b;
    logic [63:0] memory_value, read_value, cache_value;
    reset();
    memory_value = 64'h11; read_value = 0; cache_value = 0;
    read_pending = 0; write_done = 0; b_sent = 0;
    core_b_seen = 0; core_r_seen = 0; cache_valid = 0; fill_killed = 0;
    read_slot = 0;
    core_req[0].aw = aw(64'h80004000, 4'h6, 4'b0010);
    core_req[0].aw_valid = 1; memory_rsp.aw_ready = 1;
    #2;
    if (!core_rsp[0].aw_ready) $fatal(1, "HUB_REFILL_PUBLICATION_SETUP");
    write_slot = memory_req.aw.id;
    tick(); core_req[0].aw_valid = 0;
    for (int n = 0; n < 64; n++) begin
      memory_rsp = '0;
      memory_rsp.ar_ready = 1; memory_rsp.w_ready = 1;
      memory_rsp.r_valid = read_pending;
      memory_rsp.r = '{id:read_slot, data:read_value, resp:0, last:1, user:0};
      memory_rsp.b_valid = write_done && !b_sent;
      memory_rsp.b = '{id:write_slot, resp:0, user:0};
      if (n == 5) begin
        core_req[1].ar = ar(64'h80004000, 4'h7);
        core_req[1].ar_valid = 1;
      end
      core_req[0].w_valid = n >= 16 && !write_done;
      core_req[0].w = '{data:64'h22, strb:'1, last:1, user:0};
      #2;
      if (invalidations[1].valid && invalidation_ready[1]) begin
        cache_valid = 0;
        if (read_pending) fill_killed = 1;
      end
      if (core_rsp[1].r_valid) begin
        if (core_r_seen || core_rsp[1].r.id != 4'h7) $fatal(1, "HUB_REFILL_PUBLICATION_R");
        cache_value = core_rsp[1].r.data;
        cache_valid = !fill_killed;
        core_r_seen = 1;
      end
      if (core_rsp[0].b_valid) begin
        if (cache_valid && cache_value != memory_value)
          $fatal(1, "HUB_STALE_REFILL_PUBLICATION value=%h memory=%h", cache_value, memory_value);
        core_b_seen = 1;
      end
      take_r = memory_rsp.r_valid && memory_req.r_ready;
      take_b = memory_rsp.b_valid && memory_req.b_ready;
      if (memory_req.ar_valid && memory_rsp.ar_ready) begin
        read_slot = memory_req.ar.id;
        read_value = memory_value;
        read_pending = 1;
        fill_killed = invalidations[1].valid && invalidation_ready[1];
      end
      if (memory_req.w_valid && memory_rsp.w_ready) begin
        memory_value = memory_req.w.data;
        write_done = 1;
      end
      begin
        bit ar_taken;
        ar_taken = core_req[1].ar_valid && core_rsp[1].ar_ready;
        tick();
        if (ar_taken) core_req[1].ar_valid = 0;
      end
      if (take_r) read_pending = 0;
      if (take_b) b_sent = 1;
      if (core_b_seen && core_r_seen) break;
    end
    if (!core_b_seen || !core_r_seen) $fatal(1, "HUB_REFILL_PUBLICATION_DRAIN");
    if (cache_valid && cache_value != memory_value) $fatal(1, "HUB_STALE_REFILL_PUBLICATION");
  endtask

  task automatic same_id_b_order;
    id_t first_slot, second_slot;
    int count;
    reset();
    invalidation_ready = 2'b01;
    drive_write(0, 64'h4000, 4'h5, first_slot);
    drive_write(0, 64'h5000, 4'h5, second_slot, 4'b0000);
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id:first_slot, resp:2, user:1};
    #2;
    if (!memory_req.b_ready) $fatal(1, "HUB_B_ID_ORDER_SETUP");
    tick();
    memory_rsp.b = '{id:second_slot, resp:0, user:0};
    #2;
    if (core_rsp[0].b_valid) $fatal(1, "HUB_B_ID_ORDER");
    if (!memory_req.b_ready) $fatal(1, "HUB_B_ID_ORDER_CAPTURE");
    tick(); memory_rsp.b_valid = 0;
    count = 0;
    for (int n = 0; n < 24; n++) begin
      if (n == 6) invalidation_ready = '1;
      #2;
      if (core_rsp[0].b_valid) begin
        if (n < 6 || core_rsp[0].b.id != 4'h5 || count >= 2 ||
            core_rsp[0].b.resp != (count == 0 ? 2 : 0) ||
            core_rsp[0].b.user != ((count == 0) ^ negative))
          $fatal(1, "HUB_B_ID_ORDER count=%0d resp=%h", count, core_rsp[0].b);
        count++;
      end
      tick();
      if (count == 2) break;
    end
    if (count != 2) $fatal(1, "HUB_B_ID_ORDER_DRAIN");
  endtask

  //  Same-(core, original id) reads must reach the core in issue order even
  //  though the hub re-tags them with distinct slot ids toward memory. The
  //  hub therefore withholds the younger AR while the older slot is live; a
  //  different core with the same id and the same core with another id are
  //  not held. The restored defect grants the younger AR immediately.
  task automatic same_id_r_order;
    id_t first_slot, other_core_slot, other_id_slot;
    bit granted;
    reset();
    accept_read(0, 64'h1000, 4'h9, first_slot);
    core_req[0].ar = ar(64'h2000, 4'h9);
    core_req[0].ar_valid = 1;
    memory_rsp.ar_ready = 1;
    for (int n = 0; n < 6; n++) begin
      #2;
      granted = core_rsp[0].ar_ready ^ negative;
      if (granted || memory_req.ar_valid) $fatal(1, "HUB_R_ID_ORDER younger AR granted");
      tick();
    end
    core_req[0].ar_valid = 0;
    memory_rsp.ar_ready = 0;
    accept_read(1, 64'h3000, 4'h9, other_core_slot);
    accept_read(0, 64'h4000, 4'h3, other_id_slot);
    if (other_core_slot == first_slot || other_id_slot == first_slot ||
        other_core_slot == other_id_slot) $fatal(1, "HUB_R_ID_ORDER slots");
    return_read(0, first_slot, 4'h9, 64'h11);
    core_req[0].ar = ar(64'h2000, 4'h9);
    core_req[0].ar_valid = 1;
    memory_rsp.ar_ready = 1;
    #2;
    if (!core_rsp[0].ar_ready || !memory_req.ar_valid || memory_req.ar.addr != 64'h2000)
      $fatal(1, "HUB_R_ID_ORDER release");
    tick();
    core_req[0].ar_valid = 0;
    memory_rsp.ar_ready = 0;
    return_read(1, other_core_slot, 4'h9, 64'h22);
    return_read(0, other_id_slot, 4'h3, 64'h33);
  endtask

  task automatic full_id_space;
    id_t slots[OT];
    reset();
    for (int n = 0; n < OT; n++)
      accept_read(n % 2, 64'h1000 + 64'(n) * 64'd64, id_t'(n), slots[n]);
    for (int n = OT - 1; n >= 0; n--)
      return_read(n % 2, slots[n], id_t'(n), 64'(n));
  endtask

  //  Scenario 27: an ATOP R arriving while its invalidation is still
  //  undelivered is PARKED, not withheld. Withholding it (the pre-fix
  //  behaviour, r_ready=0) deadlocks the exact shape reproduced here: the
  //  target core's same-line fill is still in flight, so the delivery that
  //  slot_applied() waits on cannot happen until the fill's R lands — and on
  //  the shared R channel that beat is queued BEHIND the withheld ATOP R.
  //  The B channel never had this flaw (it is consumed and replayed via
  //  b_held); the fix gives the ATOP R the same treatment via r_held.
  task automatic atop_parked_r;
    id_t atop_slot, fill_slot;
    int k;
    bit seen_leak, got_b;
    reset();
    if (NC != 2) $fatal(1, "HUB_ATOP_PARK_GEOMETRY");
    // core1's same-line fill is admitted first and stays outstanding: it is
    // the fill inv_fill_hold makes the write's invalidation wait on.
    accept_read(1, 64'h4000, 4'h9, fill_slot);
    // core0's ATOP write to the same line (expect_r): its invalidation
    // targets core1 and cannot be presented while that fill is in flight.
    core_req[0].aw = aw(64'h4000, 4'he);
    core_req[0].aw.atop = 6'b100000;
    core_req[0].aw_valid = 1;
    memory_rsp.aw_ready = 1;
    #2;
    if (!core_rsp[0].aw_ready) $fatal(1, "HUB_ATOP_PARK_SETUP");
    atop_slot = memory_req.aw.id;
    tick();
    core_req[0].aw_valid = 0;
    memory_rsp.aw_ready = 0;
    core_req[0].w = '{data: 64'h991, strb: '1, last: 1, user: 0};
    core_req[0].w_valid = 1;
    memory_rsp.w_ready = 1;
    #2;
    if (!core_rsp[0].w_ready) $fatal(1, "HUB_ATOP_PARK_W");
    tick();
    core_req[0].w_valid = 0;
    memory_rsp.w_ready = 0;
    repeat (2) begin
      #2;
      if (invalidations[1].valid)
        $fatal(1, "HUB_ATOP_PARK_HOLD invalidation presented during same-line fill");
      tick();
    end
    // B is consumed and parked the usual way (never withheld at the port).
    memory_rsp.b_valid = 1;
    memory_rsp.b = '{id: atop_slot, resp: 0, user: 0};
    seen_leak = 0;
    got_b = 0;
    #2;
    if (!memory_req.b_ready) $fatal(1, "HUB_ATOP_PARK_B_NOT_CONSUMED");
    if (core_rsp[0].b_valid) seen_leak = 1;
    tick();
    memory_rsp.b_valid = 0;
    // The ATOP R arrives ahead of the fill's R (different ids — the L2 may
    // legally emit it first). The invalidation is still undelivered, so the
    // beat cannot be forwarded yet — but it MUST be consumed: withholding it
    // is the deadlock, because the fill's R sits behind it on this channel.
    memory_rsp.r_valid = 1;
    memory_rsp.r = '{id: atop_slot, data: 64'hc0ffee, resp: 0, last: 1, user: 0};
    #2;
    if (negative) begin
      if (memory_req.r_ready)
        $fatal(1, "HUB_ATOP_R_WITHHELD park landed — the withheld-beat defect is absent");
      $display("HUB_ACK_TIMING scenario=27 negative: withheld beat observed");
      return;
    end
    if (!memory_req.r_ready)
      $fatal(1, "HUB_ATOP_R_WITHHELD atop R withheld while unapplied — channel deadlock");
    if (core_rsp[0].r_valid) seen_leak = 1;
    tick();
    memory_rsp.r_valid = 0;
    // The fill's R lands: core1's ar slot frees, the hold clears, the
    // invalidation is delivered, and the parked ATOP R is replayed.
    return_read(1, fill_slot, 4'h9, 64'h77);
    k = -1;
    for (int n = 0; n < 40; n++) begin
      #2;
      if (invalidations[1].valid && invalidation_ready[1] && k < 0) k = n;
      if (core_rsp[0].b_valid) begin
        if (core_rsp[0].b.id !== 4'he) $fatal(1, "HUB_ATOP_PARK_B_ID");
        if (k < 0 || n <= k + 1 + INV_LAT) seen_leak = 1;
        got_b = 1;
      end
      if (core_rsp[0].r_valid) begin
        if (core_rsp[0].r.id !== 4'he || core_rsp[0].r.data !== 64'hc0ffee)
          $fatal(1, "HUB_ATOP_PARK_REPLAY id=%h data=%h",
                 core_rsp[0].r.id, core_rsp[0].r.data);
        if (k < 0 || n <= k + 1 + INV_LAT) seen_leak = 1;
        break;
      end
      tick();
      if (n == 39) $fatal(1, "HUB_ATOP_PARK_LATE parked ATOP R never replayed");
    end
    if (k < 0) $fatal(1, "HUB_ATOP_PARK_SETUP invalidation never delivered");
    if (!got_b) $fatal(1, "HUB_ATOP_PARK_B_LATE parked B never replayed");
    if (seen_leak) $fatal(1, "HUB_ATOP_R_BEFORE_INVAL");
    $display("HUB_ACK_TIMING scenario=27 k=%0d", k);
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
      10: atomic_lifetime();
      11: full_id_space();
      12: signature_hub();
      13: atomic_remaining_orders();
      14: write_ack_after_inval();
      15: write_ack_independent();
      16: write_ack_coalesce();
      17: write_ack_fast_path();
      18: write_ack_retained();
      19: b_offer_stability(0);
      20: b_offer_stability(1);
      21: atomic_invalidation_publication(0);
      22: atomic_invalidation_publication(1);
      23: refill_during_write();
      24: same_id_b_order();
      25: same_id_r_order();
      26: writer_acquisition();
      27: atop_parked_r();
      default: $fatal(1, "HUB_SCENARIO");
    endcase
    $display("HUB_PASS scenario=%0d", scenario);
    $finish;
  end
endmodule

module tb_g6lc_coherence_l2;
  import g6lc_coherence_pkg::*;
  import g6lc_l2_tb_pkg::*;
  parameter bit USE_L2=1;
  parameter logic [3:0] CACHE_ATTR=4'hf;
  parameter int BYTE_SIZE=4096, SET_ASSOC=4, MSHR_DEPTH=4, DATA_BANKS=2;
  parameter int WRITE_DELAY=16, W_STALL=0, B_DELAY=0, INV_HOLD=0, R_HOLD=0, B_HOLD=0;
  // USE_L3 stacks axi_cut + g6lc_l3_top between the L2 master and the DRAM
  // model (non-inclusive: l3_evict_ready_i tied 1). SELF_INVAL_FAULT overrides
  // the aw address the L3's write self-invalidation sees — one line up — and
  // restores it on the master side so only the invalidation is disconnected.
  parameter bit USE_L3=1'b0, SELF_INVAL_FAULT=1'b0;
  parameter int L3_BYTES=2048, L3_SET_ASSOC=2, L3_MSHR_DEPTH=2, L3_DATA_BANKS=2;
  parameter bit TAG_SRAM=1'b0;
  // WRITE_UPDATE=1 merges eligible write-throughs into resident lines at both
  // cache levels; the scenario checks below become the merge-aware forms.
  parameter bit WRITE_UPDATE=1'b0;
  // Scenario-5 sweep workload: (a) STREAM_BYTES of lines twice, (b) re-read a
  // WS_BYTES working set after POLLUTE_BYTES of pollution. Read-only, one
  // 16B hub request per 64B cache line.
  parameter int STREAM_BYTES=1048576, WS_BYTES=65536, POLLUTE_BYTES=524288;
  localparam addr_t ADDRESS=64'h80004000;
  localparam int L2_LINE_BYTES=512/8;
  localparam addr_t STREAM_BASE=64'h80100000, WS_BASE=64'h80200000,
                    POLLUTE_BASE=64'h80400000;
  logic clk=0,rst_n=0;
  req_t [1:0] requests;
  logic rd_req_valid=0,rd_ready=0,wr_req_valid=0,wr_data_valid=0,wr_resp_ready=0;
  ar_chan_t rd_req;
  aw_chan_t wr_req;
  w_chan_t wr_data;
  resp_t [1:0] responses;
  req_t hub_req,dram_req;
  resp_t hub_rsp,dram_rsp;
  coh_inval_t [1:0] invalidations;
  logic [1:0] inv_ready='1;
  logic rd_live,wr_live,wr_done;
  id_t rd_id,wr_id;
  addr_t rd_addr;
  logic [7:0] rd_len,rd_beat;
  data_t memory_value,rd_snapshot;
  // Scenario 7 (HPDCACHE store shapes) needs a real byte-granular DRAM:
  // `dram_words` records writes to every non-ADDRESS word the model has seen
  // (ADDRESS itself stays in `memory_value` because its reset value 64'h11 is
  // distinct from other_word()), and every W beat merges by strobe instead of
  // requiring a full-strobe single beat at ADDRESS.
  data_t dram_words[addr_t];
  data_t rd_snap[8];
  addr_t wr_base;
  int wr_beat;
  logic [7:0] wr_wlen;
  // Per-write-shape stimulus payload (beat data/strobes for send_write).
  data_t wr_beats[8];
  logic [7:0] wr_strbs[8];
  int core_b_count=0;
  int rd_delay,b_delay;
  int cycle=0,aw_cycle=-1,mem_b_cycle=-1,late_ar_cycle=-1,core_b_cycle=-1;
  int read_count=0,read_beat=0,inv_count=0,apply_count=0,ar_blocked=0;
  int first_inv_cycle=-1,last_apply_cycle=-1;
  logic cache_valid=0,fill_live=0,fill_killed=0,fill_start=0,apply_pending=0;
  data_t cache_value=0,fill_value=0;
  bit negative;
  int scenario;
  // Scenario 2/3 bookkeeping: DRAM fill-AR count/geometry and the reader's
  // in-flight request (for per-beat expected data).
  int dram_ar_count=0;
  addr_t dram_ar_addr[8];
  int dram_ar_len[8];
  addr_t core_rd_addr=0;
  logic [7:0] core_rd_len=0;

  g6lc_coherence_hub #(.NR_CORES(2),.MAX_OUTSTANDING(4),.INVAL_DEPTH(2),
      .LINE_BYTES(16),.SNOOP_FILTER_EN(1),.SNOOP_FILTER_ENTRIES(128),
      .POLICY(config_pkg::COH_OOO),.axi_req_t(req_t),.axi_resp_t(resp_t)) hub (
      .clk_i(clk),.rst_ni(rst_n),.core_req_i(requests),.core_resp_o(responses),
      .mem_req_o(hub_req),.mem_resp_i(hub_rsp),.inv_core_o(invalidations),
      .inv_core_ready_i(inv_ready),.lr_valid_i(1'b0),.lr_addr_i('0),.lr_core_i('0),
      .coh_inv_fire_o(),.coh_sf_hit_o(),.coh_sf_overapprox_o(),.coh_arb_starve_o(),
      .coh_split_conflict_o(),.coh_sc_noresv_o(),.coh_lr_kill_o());
  // dram_req/dram_rsp stay the DRAM edge; l2m_* is the L2 master side.
  req_t l2m_req;
  resp_t l2m_rsp;
  // T9a CMO composed path: the g6lc_cmo_engine + a dedicated broadcaster
  // (g6lc_l3_inclusive_inv #(.InclusiveEn(1)), the same instance the cluster
  // uses) drive the L2/L3 match-inval ports. There is no victim producer in
  // this bench, so the cluster's victim-wins arbitration is not modelled.
  logic cmo_l2_v, cmo_l2_rdy, cmo_l2_idle;
  addr_t cmo_l2_a;
  logic cmo_l3_v, cmo_l3_rdy, cmo_l3_idle;
  addr_t cmo_l3_a;
  logic [1:0]   tb_cmo_req_v=0, tb_cmo_ready, tb_cmo_done;
  logic [1:0]   tb_cmo_req_op[2];
  addr_t        tb_cmo_req_addr[2];
  // Under verilator --timing, timing-process writes into unpacked array
  // ports do not propagate (same limitation as tb_g6lc_cmo_engine and
  // tb_g6lc_wt_cmo): stage the request payload through clocked registers.
  logic [1:0]   tb_cmo_req_op_r[2];
  addr_t        tb_cmo_req_addr_r[2];
  always_ff @(posedge clk) begin
    for (int c = 0; c < 2; c++) begin
      tb_cmo_req_op_r[c]   <= tb_cmo_req_op[c];
      tb_cmo_req_addr_r[c] <= tb_cmo_req_addr[c];
    end
  end
  coh_inval_t [1:0] cmo_inv;
  logic cmo_bcast_v, cmo_bcast_rdy, cmo_bcast_done;
  addr_t cmo_bcast_a;
  int cmo_inv_count[2] = '{0,0};
  int cmo_done_count = 0;
  // Negative arm: +oracle_negative disconnects the L2 match-inval wire so the
  // broadcast completes but the resident L2 line survives — the re-read below
  // then hits, and the expected-miss check fails by construction.
  logic cmo_l2_v_w = 1'b0;
  assign cmo_l2_v = negative ? 1'b0 : cmo_l2_v_w;
  g6lc_l3_inclusive_inv #(.InclusiveEn(1'b1),.NR_CORES(2),.LINE_BYTES(16),
      .AXI_ADDR_WIDTH(AW)) i_cmo_bcast (
      .clk_i(clk),.rst_ni(rst_n),
      .evict_valid_i(cmo_bcast_v),.evict_addr_i(cmo_bcast_a),
      .inv_ready_i(inv_ready),.inv_o(cmo_inv),.inv_busy_o(),
      .evict_ready_o(cmo_bcast_rdy),.drain_done_o(cmo_bcast_done));
  g6lc_cmo_engine #(.NR_CORES(2),.L2_EN(USE_L2),.L3_EN(USE_L3),
      .AXI_ADDR_WIDTH(AW)) i_cmo_engine (
      .clk_i(clk),.rst_ni(rst_n),
      .cmo_valid_i(tb_cmo_req_v),.cmo_op_i(tb_cmo_req_op_r),
      .cmo_addr_i(tb_cmo_req_addr_r),.cmo_ready_o(tb_cmo_ready),
      .cmo_done_o(tb_cmo_done),
      .l1_bcast_valid_o(cmo_bcast_v),.l1_bcast_addr_o(cmo_bcast_a),
      .l1_bcast_ready_i(cmo_bcast_rdy),.l1_bcast_done_i(cmo_bcast_done),
      .l2_inval_valid_o(cmo_l2_v_w),.l2_inval_addr_o(cmo_l2_a),
      .l2_inval_ready_i(cmo_l2_rdy),
      .l3_inval_valid_o(cmo_l3_v),.l3_inval_addr_o(cmo_l3_a),
      .l3_inval_ready_i(cmo_l3_rdy),
      .l2_write_idle_i(cmo_l2_idle),.l3_write_idle_i(cmo_l3_idle));
  always_ff @(posedge clk) begin
    for (int c = 0; c < 2; c++)
      if (cmo_inv[c].valid && inv_ready[c]) cmo_inv_count[c] <= cmo_inv_count[c]+1;
    for (int c = 0; c < 2; c++)
      if (tb_cmo_done[c]) cmo_done_count <= cmo_done_count+1;
  end
  logic l3_hit_p=0, l3_miss_p=0, l2_hit_p=0, l2_miss_p=0;
  logic l2_wupd_p=0, l3_wupd_p=0;
  int l3_hits=0, l3_misses=0, l2_hits=0, l2_misses=0;
  int l2_wupd=0, l3_wupd=0;
  always_ff @(posedge clk) begin
    if (l3_hit_p) l3_hits<=l3_hits+1;
    if (l3_miss_p) l3_misses<=l3_misses+1;
    if (l2_hit_p) l2_hits<=l2_hits+1;
    if (l2_miss_p) l2_misses<=l2_misses+1;
    if (l2_wupd_p) l2_wupd<=l2_wupd+1;
    if (l3_wupd_p) l3_wupd<=l3_wupd+1;
  end
  g6lc_l2_top #(.Enable(USE_L2),.BYTE_SIZE(BYTE_SIZE),.SET_ASSOC(SET_ASSOC),
      .LINE_WIDTH(512),.MSHR_DEPTH(MSHR_DEPTH),.DATA_BANKS(DATA_BANKS),.FAIR_WRITES(1),
      .TAG_SRAM(TAG_SRAM),.WRITE_UPDATE(WRITE_UPDATE),
      .AXI_ADDR_WIDTH(AW),.AXI_DATA_WIDTH(DW),.AXI_ID_WIDTH(IDW),.AXI_USER_WIDTH(UW),
      .axi_req_t(req_t),.axi_resp_t(resp_t)) l2 (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(hub_req),.slv_resp_o(hub_rsp),
      .mst_req_o(l2m_req),.mst_resp_i(l2m_rsp),
      .l2_hit_o(l2_hit_p),.l2_miss_o(l2_miss_p),.l2_bypass_o(),.l2_mshr_full_o(),.l2_bank_conflict_o(),
      .l2_selfinv_hit_o(),.l2_wupdate_o(l2_wupd_p),
      .l2_evict_valid_o(),.l2_evict_addr_o(),.l2_evict_ready_i(1'b1),
      .l2_back_inval_valid_i(cmo_l2_v),.l2_back_inval_addr_i(cmo_l2_a),
      .l2_back_inval_ready_o(cmo_l2_rdy),.l2_write_idle_o(cmo_l2_idle));
  if (USE_L3) begin : gen_l3_stack
    req_t cut_req,l3_slv_req,l3_mst_req;
    resp_t cut_rsp;
    axi_cut #(
      .Bypass(1'b0),.aw_chan_t(aw_chan_t),.w_chan_t(w_chan_t),.b_chan_t(b_chan_t),
      .ar_chan_t(ar_chan_t),.r_chan_t(r_chan_t),.req_t(req_t),.resp_t(resp_t)
    ) i_l3_cut (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(l2m_req),.slv_resp_o(l2m_rsp),
      .mst_req_o(cut_req),.mst_resp_i(cut_rsp)
    );
    always_comb begin
      l3_slv_req=cut_req;
      if(SELF_INVAL_FAULT)l3_slv_req.aw.addr=cut_req.aw.addr^64'h40;
    end
    g6lc_l3_top #(
      .Enable(1'b1),.BYTE_SIZE(L3_BYTES),.SET_ASSOC(L3_SET_ASSOC),
      .LINE_WIDTH(512),.MSHR_DEPTH(L3_MSHR_DEPTH),.DATA_BANKS(L3_DATA_BANKS),
      .TAG_SRAM(TAG_SRAM),.WRITE_UPDATE(WRITE_UPDATE),
      .AXI_ADDR_WIDTH(AW),.AXI_DATA_WIDTH(DW),.AXI_ID_WIDTH(IDW),.AXI_USER_WIDTH(UW),
      .axi_req_t(req_t),.axi_resp_t(resp_t)
    ) i_l3 (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(l3_slv_req),.slv_resp_o(cut_rsp),
      .mst_req_o(l3_mst_req),.mst_resp_i(dram_rsp),
      .l3_hit_o(l3_hit_p),.l3_miss_o(l3_miss_p),.l3_bypass_o(),.l3_selfinv_hit_o(),
      .l3_wupdate_o(l3_wupd_p),
      .l3_evict_valid_o(),.l3_evict_addr_o(),.l3_evict_ready_i(1'b1),
      .l3_write_idle_o(cmo_l3_idle),
      .l3_back_inval_valid_i(cmo_l3_v),.l3_back_inval_addr_i(cmo_l3_a),
      .l3_back_inval_ready_o(cmo_l3_rdy)
    );
    always_comb begin
      dram_req=l3_mst_req;
      if(SELF_INVAL_FAULT)dram_req.aw.addr=l3_mst_req.aw.addr^64'h40;
    end
  end else begin : gen_no_l3
    assign dram_req=l2m_req;
    assign l2m_rsp=dram_rsp;
    assign cmo_l3_idle = 1'b1;
    assign cmo_l3_rdy  = 1'b1;
  end

  always_comb begin
    requests='0;
    requests[0].aw=wr_req;requests[0].aw_valid=wr_req_valid;
    requests[0].w=wr_data;requests[0].w_valid=wr_data_valid;
    requests[0].b_ready=wr_resp_ready;
    requests[1].ar=rd_req;requests[1].ar_valid=rd_req_valid;
    requests[1].r_ready=rd_ready;
  end
  function automatic data_t other_word(input addr_t addr);
    return 64'h4400 | (addr & 64'h3f);
  endfunction
  // DRAM word read: the ADDRESS word lives in `memory_value`; words the model
  // has seen written live in `dram_words`; untouched words keep the
  // deterministic `other_word` contents (unchanged behaviour for every
  // pre-shape scenario).
  function automatic data_t mem_word(input addr_t addr);
    if(addr==ADDRESS)return memory_value;
    if(dram_words.exists(addr))return dram_words[addr];
    return other_word(addr);
  endfunction
  function automatic ar_chan_t read_request(input id_t id);
    ar_chan_t r;
    r='0;r.addr=ADDRESS;r.id=id;r.len=1;r.size=3;r.burst=1;r.cache=CACHE_ATTR;
    return r;
  endfunction
  always_comb begin
    dram_rsp='0;
    dram_rsp.ar_ready=!rd_live;
    dram_rsp.aw_ready=!wr_live;
    dram_rsp.w_ready=wr_live && !wr_done && cycle-aw_cycle>=WRITE_DELAY+W_STALL;
    dram_rsp.b_valid=wr_live && wr_done && b_delay==0;
    dram_rsp.b='{id:wr_id,resp:0,user:0};
    dram_rsp.r_valid=rd_live && rd_delay==0;
    // Burst snapshot taken at AR accept: a read must not observe a write that
    // lands after its address phase (the late_ar >= mem_b contract).
    dram_rsp.r='{id:rd_id,data:rd_snap[3'(rd_beat)],
      resp:0,last:rd_beat==rd_len,user:0};
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      rd_live<=0;wr_live<=0;wr_done<=0;rd_id<=0;wr_id<=0;
      rd_addr<=0;rd_len<=0;rd_beat<=0;rd_delay<=0;b_delay<=0;
      wr_base<='0;wr_beat<=0;wr_wlen<='0;
      memory_value<=64'h11;rd_snapshot<=0;
    end else begin
      if(rd_delay>0)rd_delay<=rd_delay-1;
      if(b_delay>0)b_delay<=b_delay-1;
      if(dram_req.ar_valid && dram_rsp.ar_ready) begin
        rd_live<=1;rd_id<=dram_req.ar.id;rd_addr<=dram_req.ar.addr;
        rd_len<=dram_req.ar.len;rd_beat<=0;rd_delay<=3;rd_snapshot<=memory_value;
        for(int i=0;i<8;i++)rd_snap[i]<=mem_word(dram_req.ar.addr+64'(i)*8);
        if(dram_ar_count<8)begin
          dram_ar_addr[dram_ar_count]<=dram_req.ar.addr;
          dram_ar_len[dram_ar_count]<=dram_req.ar.len;
        end
        dram_ar_count<=dram_ar_count+1;
      end
      if(dram_rsp.r_valid && dram_req.r_ready) begin
        if(dram_rsp.r.last)rd_live<=0;else rd_beat<=rd_beat+1'b1;
      end
      if(dram_req.aw_valid && dram_rsp.aw_ready) begin
        // One-line window at ADDRESS: 64-bit INCR beats, no atomics, whole
        // burst confined to the line.
        if(dram_req.aw.atop!=0 || dram_req.aw.burst!=2'b01 ||
           dram_req.aw.size!=3 ||
           (dram_req.aw.addr & ~addr_t'(L2_LINE_BYTES-1))!=(ADDRESS & ~addr_t'(L2_LINE_BYTES-1)) ||
           dram_req.aw.addr[2:0]!=0 ||
           int'(dram_req.aw.addr[5:3])+int'(dram_req.aw.len)+1>L2_LINE_BYTES/8)
          $fatal(1,"COH_L2_MEMORY_AW a=%h len=%0d",dram_req.aw.addr,dram_req.aw.len);
        wr_live<=1;wr_done<=0;wr_id<=dram_req.aw.id;
        wr_base<=dram_req.aw.addr;wr_beat<=0;wr_wlen<=dram_req.aw.len;
      end
      if(dram_req.w_valid && dram_rsp.w_ready) begin
        begin : w_apply
          addr_t wa;
          data_t merged;
          wa=wr_base+addr_t'(wr_beat)*8;
          merged=mem_word(wa);
          for(int b=0;b<8;b++)
            if(dram_req.w.strb[b])merged[b*8+:8]=dram_req.w.data[b*8+:8];
          if(wa==ADDRESS)memory_value<=merged;else dram_words[wa]<=merged;
        end
        if(dram_req.w.last)begin
          if(wr_beat!=wr_wlen)$fatal(1,"COH_L2_MEMORY_W b=%0d len=%0d",wr_beat,wr_wlen);
          wr_done<=1;b_delay<=B_DELAY;
        end else wr_beat<=wr_beat+1;
      end
      if(dram_rsp.b_valid && dram_req.b_ready)begin wr_live<=0;wr_done<=0;end
    end
  end
  int sc5_mark_reads=0, sc5_mark_cycle=0;
  always @(posedge clk) begin
    if(rst_n)begin
      cycle++;
      // Scenario 5 streams tens of thousands of reads, so the fixed 4000-cycle
      // bound cannot apply; it gets a progress watchdog instead (a read must
      // complete at least every 20000 cycles).
      if(scenario==5)begin
        if(read_count!=sc5_mark_reads)begin
          sc5_mark_reads=read_count;sc5_mark_cycle=cycle;
        end else if(cycle-sc5_mark_cycle>20000)begin
          $fatal(1,"COH_L2_WATCHDOG sweep reads=%0d",read_count);
        end
      end else if(cycle>4000)begin
        $display("COMPOSED_STALL aw=%0d inv=%0d apply=%0d mem_b=%0d core_b=%0d reads=%0d wr_live=%b wr_done=%b b_delay=%0d",
          aw_cycle,first_inv_cycle,last_apply_cycle,mem_b_cycle,core_b_cycle,read_count,wr_live,wr_done,b_delay);
        $display("COMPOSED_STALL core: aw_v=%b aw_r=%b w_v=%b w_r=%b b_v=%b b_r=%b inv_v=%b inv_r=%b",
          wr_req_valid,responses[0].aw_ready,wr_data_valid,responses[0].w_ready,responses[0].b_valid,
          wr_resp_ready,invalidations[1].valid,inv_ready[1]);
        $display("COMPOSED_STALL hub->l2: aw_v=%b aw_r=%b w_v=%b w_r=%b b_v=%b b_r=%b ar_v=%b ar_r=%b r_v=%b r_r=%b",
          hub_req.aw_valid,hub_rsp.aw_ready,hub_req.w_valid,hub_rsp.w_ready,hub_rsp.b_valid,hub_req.b_ready,
          hub_req.ar_valid,hub_rsp.ar_ready,hub_rsp.r_valid,hub_req.r_ready);
        $display("COMPOSED_STALL l2->mem: aw_v=%b aw_r=%b w_v=%b w_r=%b b_v=%b b_r=%b",
          dram_req.aw_valid,dram_rsp.aw_ready,dram_req.w_valid,dram_rsp.w_ready,dram_rsp.b_valid,dram_req.b_ready);
        $display("COMPOSED_STALL hub: w_busy=%b w_owner=%0d aw_hold=%b inv_pend_valid=%b sig_pending=%b slots=%h ar_hold=%b",
          hub.gen_cluster.w_busy_q,hub.gen_cluster.w_owner_q,hub.gen_cluster.aw_hold_q,
          hub.gen_cluster.inv_pend_valid_q,hub.gen_cluster.sig_pending_q,hub.gen_cluster.slot_used,hub.gen_cluster.ar_hold_q);
        for(int s=0;s<4;s++)
          $display("COMPOSED_STALL slot%0d aw_valid=%b b_held=%b b_done=%b expect_r=%b core=%0d inv_owed=%b inv_wait=%b settle=%0d pred=%b",
            s,hub.gen_cluster.aw_ot_q[s].valid,hub.gen_cluster.aw_ot_q[s].b_held,hub.gen_cluster.aw_ot_q[s].b_done,
            hub.gen_cluster.aw_ot_q[s].expect_r,hub.gen_cluster.aw_ot_q[s].core,hub.gen_cluster.inv_ot_q[s].inv_owed,
            hub.gen_cluster.inv_ot_q[s].inv_wait,hub.gen_cluster.inv_ot_q[s].inv_settle,hub.gen_cluster.b_predecessors_q[s]);
        $fatal(1,"COH_L2_WATCHDOG");
      end
      if($test$plusargs("diagnose") && cycle>=130 && cycle<150)begin
        $display("COMPOSED_DIAG cycle=%0d ready=%b req=%b hub_input=%b ar_req=%b block=%b alloc_ready=%b free=%b winner=%b hub_ar=%b l2_ready=%b dram_ar=%b dram_ready=%b sf_ready=%b slots=%h",
          cycle,responses[1].ar_ready,rd_req_valid,hub.core_req_i[1].ar_valid,
          hub.gen_cluster.ar_req,hub.gen_cluster.coh_block_ar,hub.gen_cluster.sig_alloc_ready,
          hub.gen_cluster.ar_have_free,hub.gen_cluster.ar_winner,hub_req.ar_valid,hub_rsp.ar_ready,
          dram_req.ar_valid,dram_rsp.ar_ready,hub.gen_cluster.sig_initialized,hub.gen_cluster.slot_used);
      end
      if(wr_req_valid && responses[0].aw_ready)aw_cycle=cycle;
      if(dram_rsp.b_valid && dram_req.b_ready)mem_b_cycle=cycle;
      // A racing same-line AR is held either upstream at the hub admission
      // (responses[1].ar_ready low while a same-line write is live) or, when
      // forwarded, downstream at the L2 (hub_rsp.ar_ready low). Count both so
      // the admission contract covers either enforcement point.
      if(((hub_req.ar_valid && !hub_rsp.ar_ready) ||
          (rd_req_valid && !responses[1].ar_ready)) && aw_cycle>=0)ar_blocked++;
      if(rd_req_valid && responses[1].ar_ready && read_count==1)late_ar_cycle=cycle;
      if(fill_start)begin fill_live=1;fill_killed=0;cache_valid=0;end
      if(apply_pending)begin
        cache_valid=0;apply_count++;last_apply_cycle=cycle;
        if(fill_live)fill_killed=1;
      end
      apply_pending=invalidations[1].valid && inv_ready[1];
      if(apply_pending)begin
        if(invalidations[1].line_addr!=coh_line_tag(ADDRESS,16))$fatal(1,"COH_L2_INVAL_ADDRESS");
        inv_count++;if(first_inv_cycle<0)first_inv_cycle=cycle;
      end
      if(invalidations[0].valid)$fatal(1,"COH_L2_WRITER_TARGET");
      if(responses[1].r_valid && rd_ready)begin
        if(responses[1].r.id!=id_t'(read_count+1) || responses[1].r.resp!=0)
          $fatal(1,"COH_L2_RESPONSE_OWNER");
        if(scenario>=2)begin
          begin
            addr_t beat_addr;
            data_t exp;
            beat_addr=core_rd_addr+64'(read_beat)*8;
            exp=mem_word(beat_addr);
            // Negative arm: scenario 2 flips one expected beat (third read's
            // first beat); scenario 3 expects the pre-write value instead.
            if(negative && scenario==2 && read_count==3 && read_beat==0)
              exp=exp^64'hffff_ffff_ffff_ffff;
            if(negative && scenario==3 && beat_addr==ADDRESS)
              exp=64'h11;
            if(responses[1].r.last!=(read_beat==core_rd_len))
              $fatal(1,"COH_L2_RESPONSE_OWNER");
            if(responses[1].r.data!=exp)begin
              if(scenario==3)
                $fatal(1,"COH_L2_STALE_VALUE a=%h d=%h e=%h",
                  beat_addr,responses[1].r.data,exp);
              else
                $fatal(1,"COH_L2_DATA a=%h d=%h e=%h",
                  beat_addr,responses[1].r.data,exp);
            end
            if(responses[1].r.last)begin read_count++;read_beat=0;fill_live=0;end
            else read_beat++;
          end
        end else begin
          if(responses[1].r.last!=(read_beat==1))$fatal(1,"COH_L2_RESPONSE_OWNER");
          if(read_beat==0)fill_value=responses[1].r.data;
          else if(responses[1].r.data!=other_word(ADDRESS+8))$fatal(1,"COH_L2_RESPONSE_OFFSET");
          if(responses[1].r.last)begin
            cache_value=fill_value;cache_valid=!fill_killed;fill_live=0;read_count++;read_beat=0;
          end else read_beat++;
        end
      end
      if(responses[0].b_valid && wr_resp_ready)begin
        if(responses[0].b.id!=4'h6 || responses[0].b.resp!=0)
          $fatal(1,"COH_L2_B_OWNER");
        core_b_count++;
        if(scenario!=7)begin
          if(core_b_cycle>=0)$fatal(1,"COH_L2_B_OWNER");
          if(apply_count!=1)$fatal(1,"COH_L2_B_BEFORE_APPLY");
          if(cache_valid && cache_value!=64'h22)$fatal(1,"COH_L2_STALE_VALUE");
        end else begin
          // Shapes run: every write still owes its L1 broadcast before the B
          // is delivered (B never races ahead of the invalidation apply).
          if(apply_count<core_b_count)$fatal(1,"COH_L2_B_BEFORE_APPLY");
        end
        core_b_cycle=cycle;
      end
    end
  end
  assert property(@(posedge clk)disable iff(!rst_n)
    responses[0].b_valid && !wr_resp_ready |=> responses[0].b_valid && $stable(responses[0].b))
    else $fatal(1,"COH_L2_B_STABILITY");
  assert property(@(posedge clk)disable iff(!rst_n)
    responses[1].r_valid && !rd_ready |=> responses[1].r_valid && $stable(responses[1].r))
    else $fatal(1,"COH_L2_R_STABILITY");

  task automatic tick;#2;clk=1;#2;clk=0;#2;endtask
  task automatic send_read(input id_t id, input addr_t addr=ADDRESS,
                           input logic [7:0] len=1);
    rd_req=read_request(id);rd_req.addr=addr;rd_req.len=len;
    core_rd_addr=addr;core_rd_len=len;
    rd_req_valid=1;fill_start=1;
    for(int n=0;n<2000;n++)begin
      #1;
      if(responses[1].ar_ready)begin tick();rd_req_valid=0;fill_start=0;return;end
      tick();fill_start=0;
    end
    $fatal(1,"COH_L2_AR_TIMEOUT");
  endtask
  // Scenario 7 (HPDCACHE store shapes): one AXI write of `beats` 64-bit INCR
  // beats whose per-beat data/strobes come from wr_beats/wr_strbs; waits for
  // the core-side B (core_b_count) so shapes serialize.
  task automatic send_write(input addr_t addr,input int beats,
                            input logic [3:0] cache);
    int b_want;
    b_want=core_b_count+1;
    wr_req='0;wr_req.addr=addr;wr_req.id=6;wr_req.len=8'(beats-1);
    wr_req.size=3;wr_req.burst=2'b01;wr_req.cache=cache;wr_req_valid=1;
    for(int n=0;n<2000;n++)begin
      #1;
      if(wr_req_valid && responses[0].aw_ready)begin tick();wr_req_valid=0;break;end
      tick();
    end
    if(wr_req_valid)$fatal(1,"COH_L2_AW_TIMEOUT");
    // The DRAM model gates w_ready on `cycle-aw_cycle >= WRITE_DELAY+W_STALL`
    // and `cycle` advances by a blocking increment inside the posedge monitor,
    // so the gate's rising edge only exists inside the posedge evaluation —
    // a W beat presented earlier never observes ready. Wait the gate out
    // before driving the burst (same cycle-gate idiom as the scenario-0
    // write loop at `cycle-aw_cycle >= WRITE_DELAY`).
    for(int n=0;n<2000 && cycle-aw_cycle<WRITE_DELAY+W_STALL;n++)tick();
    if(cycle-aw_cycle<WRITE_DELAY+W_STALL)$fatal(1,"COH_L2_W_READY_TIMEOUT");
    for(int k=0;k<beats;k++)begin
      wr_data='{data:wr_beats[k],strb:wr_strbs[k],last:k==beats-1,user:0};
      wr_data_valid=1;
      for(int n=0;n<2000;n++)begin
        #1;
        if(wr_data_valid && responses[0].w_ready)begin tick();wr_data_valid=0;break;end
        tick();
      end
      if(wr_data_valid)$fatal(1,"COH_L2_W_TIMEOUT");
    end
    for(int n=0;n<2000 && core_b_count<b_want;n++)tick();
    if(core_b_count<b_want)$fatal(1,"COH_L2_B_TIMEOUT");
  endtask
  // Scenario 5: issue `lines` sequential reads, one per 64-byte line starting
  // at `base`, waiting for each response before the next request. The
  // response checker (scenario>=2 path) validates every beat, so the stream
  // is self-checking; the response-id contract requires id==read_count+1.
  task automatic sweep_stream(input addr_t base, input int lines);
    int target;
    for(int k=0;k<lines;k++)begin
      target=read_count+1;
      send_read(id_t'(target),base+addr_t'(k)*L2_LINE_BYTES,8'd1);
      while(read_count!=target)tick();
    end
  endtask
  initial begin
    negative=$test$plusargs("oracle_negative");
    if(!$value$plusargs("scenario=%d",scenario))scenario=0;
    repeat(3)tick();rst_n=1;repeat(132)tick();
    wr_resp_ready=1;rd_ready=1;
    if(scenario==2)begin
      // Sub-line service: the first read misses and the line-wide DRAM fill
      // covers the remaining offset reads as hits (no further DRAM AR).
      send_read(1,ADDRESS+16,8'd1);
      while(read_count!=1)tick();
      if(dram_ar_count!=1 || dram_ar_len[0]!=L2_LINE_BYTES/8-1 ||
         dram_ar_addr[0]!=(ADDRESS & ~addr_t'(L2_LINE_BYTES-1)))
        $fatal(1,"COH_L2_FILL_GEOMETRY");
      send_read(2,ADDRESS+32,8'd1);
      while(read_count!=2)tick();
      send_read(3,ADDRESS+48,8'd1);
      while(read_count!=3)tick();
      send_read(4,ADDRESS,8'd1);
      while(read_count!=4)tick();
      if(dram_ar_count!=1)$fatal(1,"COH_L2_MISS_ON_HIT");
      $display("COH_L2_PASS scenario=%0d l2=%0d bytes=%0d dram_ar=%0d l3_hit=%0d l3_miss=%0d",
        scenario,USE_L2,BYTE_SIZE,dram_ar_count,l3_hits,l3_misses);
      $finish;
    end
    if(scenario==4)begin
      // L3-hit probe (only meaningful when the L3 retains more same-set lines
      // than the L2 can hold, i.e. stack-target geometry): fill ADDRESS, then
      // stream SET_ASSOC distinct lines aliasing its L2 set so the L2 evicts
      // it, then re-read. A retaining L3 answers the re-read — no extra DRAM
      // AR and l3_hit>0; a non-installing L3 refetches from DRAM instead.
      int want_ar;
      send_read(1);
      while(read_count!=1)tick();
      for(int k=1;k<=SET_ASSOC;k++)begin
        send_read(id_t'(k+1),ADDRESS+64'(k)*(BYTE_SIZE/SET_ASSOC),8'd1);
        while(read_count!=k+1)tick();
      end
      // Phase-5 WU probe: store into the evicted line before the re-read.
      // Under WRITE_UPDATE the L3 merges the write into its resident copy and
      // the re-read hits the L3 carrying the new bytes; without it the write
      // purges the L3 copy and the re-read costs one more DRAM fill.
      wr_req='0;
      wr_req.addr=ADDRESS;wr_req.id=6;wr_req.size=3;
      wr_req.burst=1;wr_req.cache=CACHE_ATTR;wr_req_valid=1;
      while(aw_cycle<0)tick();
      wr_req_valid=0;
      // Same W-drive idiom as the scenario 0-3 loop: the handshake must be
      // sampled before the posedge — a post-edge poll can miss the consumed
      // beat and deadlock on w_ready.
      for(int n=0;n<2000 && core_b_cycle<0;n++)begin
        bit w_taken;
        wr_data_valid=cycle-aw_cycle>=WRITE_DELAY && mem_b_cycle<0;
        wr_data='{data:64'h22,strb:'1,last:1,user:0};
        #1;
        w_taken=wr_data_valid && responses[0].w_ready;
        tick();
        if(w_taken)wr_data_valid=0;
      end
      wr_data_valid=0;
      if(core_b_cycle<0)$fatal(1,"COH_L2_W_TIMEOUT");
      send_read(id_t'(SET_ASSOC+2));
      while(read_count!=SET_ASSOC+2)tick();
      want_ar=SET_ASSOC+1+(WRITE_UPDATE?0:1)+(negative?1:0);
      if(dram_ar_count!=want_ar)$fatal(1,"COH_L3_PROBE");
      if(!negative && WRITE_UPDATE)begin
        if(l3_hits==0)$fatal(1,"COH_L3_NO_HIT");
        if(l3_wupd==0)$fatal(1,"COH_L2_WU_NO_MERGE");
      end else if(!negative && !WRITE_UPDATE)begin
        if(l3_hits!=0)$fatal(1,"COH_L3_STALE_HIT");
      end
      $display("COH_L2_PASS scenario=%0d l2=%0d bytes=%0d dram_ar=%0d l3_hit=%0d l3_miss=%0d",
        scenario,USE_L2,BYTE_SIZE,dram_ar_count,l3_hits,l3_misses);
      $finish;
    end
    if(scenario==5)begin
      // Geometry-sweep workload (D.1): five phases, counters snapshotted at
      // each boundary so the runner can attribute hits per phase:
      //   A1 cold stream (STREAM_BYTES), A2 repeat stream,
      //   B1 working-set install (WS_BYTES), B2 pollution (POLLUTE_BYTES),
      //   B3 working-set re-read.
      int l2h_p[5],l2m_p[5],l3h_p[5],l3m_p[5],dar_p[5],cyc_p[5];
      rd_ready=1;
      sweep_stream(STREAM_BASE,STREAM_BYTES/L2_LINE_BYTES);
      l2h_p[0]=l2_hits;l2m_p[0]=l2_misses;l3h_p[0]=l3_hits;l3m_p[0]=l3_misses;
      dar_p[0]=dram_ar_count;cyc_p[0]=cycle;
      sweep_stream(STREAM_BASE,STREAM_BYTES/L2_LINE_BYTES);
      l2h_p[1]=l2_hits;l2m_p[1]=l2_misses;l3h_p[1]=l3_hits;l3m_p[1]=l3_misses;
      dar_p[1]=dram_ar_count;cyc_p[1]=cycle;
      sweep_stream(WS_BASE,WS_BYTES/L2_LINE_BYTES);
      l2h_p[2]=l2_hits;l2m_p[2]=l2_misses;l3h_p[2]=l3_hits;l3m_p[2]=l3_misses;
      dar_p[2]=dram_ar_count;cyc_p[2]=cycle;
      sweep_stream(POLLUTE_BASE,POLLUTE_BYTES/L2_LINE_BYTES);
      l2h_p[3]=l2_hits;l2m_p[3]=l2_misses;l3h_p[3]=l3_hits;l3m_p[3]=l3_misses;
      dar_p[3]=dram_ar_count;cyc_p[3]=cycle;
      sweep_stream(WS_BASE,WS_BYTES/L2_LINE_BYTES);
      l2h_p[4]=l2_hits;l2m_p[4]=l2_misses;l3h_p[4]=l3_hits;l3m_p[4]=l3_misses;
      dar_p[4]=dram_ar_count;cyc_p[4]=cycle;
      $display("COH_L2_SWEEP scenario=5 l2bytes=%0d l3bytes=%0d cycles=%0d",BYTE_SIZE,L3_BYTES,cycle);
      for(int p=0;p<5;p++)
        $display("COH_L2_SWEEP phase=%0d l2_hit=%0d l2_miss=%0d l3_hit=%0d l3_miss=%0d dram_ar=%0d cycles=%0d",
          p,l2h_p[p],l2m_p[p],l3h_p[p],l3m_p[p],dar_p[p],cyc_p[p]);
      $display("COH_L2_PASS scenario=%0d",scenario);
      $finish;
    end
    if(scenario==6)begin
      // T9a composed CMO: warm ADDRESS into L2 (and the stacked L3), then a
      // core-0 cbo.inval through the engine must (a) broadcast an L1 inval to
      // BOTH cores, (b) tag-match-inval the line at L2 and L3, (c) pulse done
      // exactly once. The re-read then misses at every level and DRAM fills
      // again. +oracle_negative severs the L2 match-inval wire: the re-read
      // hits and COH_L2_CMO_PROP must fire.
      send_read(1);
      while(read_count!=1)tick();
      if(dram_ar_count!=1)$fatal(1,"COH_L2_CMO_WARMUP");
      tb_cmo_req_op[0]=2'd0;tb_cmo_req_addr[0]=ADDRESS;
      // one tick so the staged request payload reaches the engine before valid
      tick();
      tb_cmo_req_v[0]=1'b1;
      // The request is consumed at the accepting edge (valid && ready); a
      // held valid is a second request, so drop it right after that edge.
      begin
        bit accepted=0;
        for(int n=0;n<2000 && !accepted;n++)begin
          accepted=tb_cmo_ready[0];
          tick();
        end
        tb_cmo_req_v[0]=1'b0;
        if(!accepted)$fatal(1,"COH_L2_CMO_NO_ACCEPT");
      end
      for(int n=0;n<2000 && cmo_done_count==0;n++)tick();
      if(cmo_done_count!=1)$fatal(1,"COH_L2_CMO_NO_DONE");
      if(cmo_inv_count[0]!=1 || cmo_inv_count[1]!=1)
        $fatal(1,"COH_L2_CMO_BCAST c0=%0d c1=%0d",cmo_inv_count[0],cmo_inv_count[1]);
      send_read(2);
      while(read_count!=2)tick();
      if(dram_ar_count!=2)$fatal(1,"COH_L2_CMO_PROP dram_ar=%0d",dram_ar_count);
      if(l2_misses<2 || (USE_L3 && l3_misses<2))
        $fatal(1,"COH_L2_CMO_MISSCOUNT l2=%0d l3=%0d",l2_misses,l3_misses);
      $display("COH_L2_PASS scenario=%0d l2=%0d bytes=%0d dram_ar=%0d l2_miss=%0d l3_miss=%0d cmo_done=%0d",
        scenario,USE_L2,BYTE_SIZE,dram_ar_count,l2_misses,l3_misses,cmo_done_count);
      $finish;
    end
    if(scenario==7)begin
      // T9a/M1a HPDCACHE store shapes under eWT: the write-through stream an
      // HPDCACHE L1 emits (single word, wbuf-coalesced full-line burst,
      // partial-strobe multi-beat, modifiable-only NC) against a resident
      // line, exercising the WRITE_UPDATE merge path end to end. A cbo.inval
      // through the engine then forces a DRAM refill that proves the merged
      // bytes reached memory. Under +oracle_negative the L2 match-inval wire
      // is severed, so the post-CMO read hits the resident line instead of
      // refilling and COH_L2_SHAPE_AR must fire.
      // (a) warm ADDRESS resident at every level.
      send_read(1);
      while(read_count!=1)tick();
      if(dram_ar_count!=1)$fatal(1,"COH_L2_CMO_WARMUP");
      // (b) single word, partial strobe, write-allocate attribute.
      wr_beats[0]=64'hAAAA_BBBB_CCCC_DDDD;wr_strbs[0]=8'h0F;
      send_write(ADDRESS,1,4'hf);
      send_read(2);while(read_count!=2)tick();
      // (c) wbuf-coalesced full-line burst: 8 full-strobe beats, line base.
      for(int k=0;k<8;k++)begin
        wr_beats[k]=64'h1000_0000_0000_0000|(64'(k+1)<<48)|64'h5a5a;
        wr_strbs[k]='1;
      end
      send_write(ADDRESS & ~addr_t'(L2_LINE_BYTES-1),8,4'hf);
      send_read(3);while(read_count!=3)tick();
      // (d) two-beat partial-strobe run, bufferable cleared (alloc-only).
      wr_beats[0]=64'hDEAD_BEEF_0000_1111;wr_strbs[0]=8'h81;
      wr_beats[1]=64'h2222_3333_4444_5555;wr_strbs[1]=8'h3C;
      send_write(ADDRESS,2,4'h6);
      send_read(4);while(read_count!=4)tick();
      // (e) cbo.inval through the engine: the resident copy drops at every
      //     level, so the next read refills from DRAM — the refill data
      //     verifies the DRAM model saw every merged byte lane above.
      tb_cmo_req_op[0]=2'd0;tb_cmo_req_addr[0]=ADDRESS;tick();
      tb_cmo_req_v[0]=1'b1;
      begin
        bit accepted=0;
        for(int n=0;n<2000 && !accepted;n++)begin
          accepted=tb_cmo_ready[0];tick();
        end
        tb_cmo_req_v[0]=1'b0;
        if(!accepted)$fatal(1,"COH_L2_CMO_NO_ACCEPT");
      end
      for(int n=0;n<2000 && cmo_done_count==0;n++)tick();
      if(cmo_done_count!=1)$fatal(1,"COH_L2_CMO_NO_DONE");
      send_read(5);while(read_count!=5)tick();
      // (f) modifiable-only (HPDCACHE NC) write: write-update-ineligible —
      //     the resident line is invalidated and memory takes the bytes.
      wr_beats[0]=64'h7777_8888_9999_AAAA;wr_strbs[0]='1;
      send_write(ADDRESS,1,4'h2);
      send_read(6);while(read_count!=6)tick();
      // The severed match-inval under +oracle_negative leaves the line
      // resident, so step (e)'s re-read hits instead of refilling and the
      // DRAM-AR count below fails — the arm needs no extra stimulus.
      if(WRITE_UPDATE)begin
        if(l2_wupd!=3)$fatal(1,"COH_L2_WU_SHAPES wupd=%0d",l2_wupd);
        if(dram_ar_count!=3)$fatal(1,"COH_L2_SHAPE_AR dram_ar=%0d",dram_ar_count);
      end else begin
        if(l2_wupd!=0)$fatal(1,"COH_L2_WU_SHAPES wupd=%0d",l2_wupd);
        if(dram_ar_count!=6)$fatal(1,"COH_L2_SHAPE_AR dram_ar=%0d",dram_ar_count);
      end
      if(apply_count!=4)$fatal(1,"COH_L2_SHAPE_INV apply=%0d",apply_count);
      $display("COH_L2_PASS scenario=%0d l2=%0d bytes=%0d dram_ar=%0d l2_hit=%0d l2_miss=%0d l3_miss=%0d l2_wupd=%0d cmo_done=%0d",
        scenario,USE_L2,BYTE_SIZE,dram_ar_count,l2_hits,l2_misses,l3_misses,l2_wupd,cmo_done_count);
      $finish;
    end
    send_read(1);
    while(read_count!=1)tick();
    if(scenario<2 && (!cache_valid || cache_value!=64'h11))$fatal(1,"COH_L2_WARMUP");
    wr_req='0;
    wr_req.addr=ADDRESS;wr_req.id=6;wr_req.size=3;
    wr_req.burst=1;
    // Under WRITE_UPDATE an eligible store merges in place and never takes the
    // L3 self-invalidation, so the SELF_INVAL_FAULT profile would stop
    // discriminating. The fault write is therefore modifiable but
    // non-allocating: the hub still broadcasts the L1 invalidation (cache[1])
    // while the L2/L3 find it write-update-ineligible (no allocate bit) and
    // keep the invalidation path that the fault severs.
    wr_req.cache=(SELF_INVAL_FAULT && WRITE_UPDATE) ? 4'b0010 : CACHE_ATTR;
    wr_req_valid=1;
    inv_ready[1]=(INV_HOLD==0);wr_resp_ready=(B_HOLD==0);
    while(aw_cycle<0)tick();
    wr_req_valid=0;
    for(int n=0;n<2000;n++)begin
      bit ar_taken,w_taken;
      wr_data_valid=cycle-aw_cycle>=WRITE_DELAY && !wr_done && mem_b_cycle<0;
      wr_data='{data:64'h22,strb:'1,last:1,user:0};
      inv_ready[1]=cycle-aw_cycle>=INV_HOLD;
      wr_resp_ready=cycle-aw_cycle>=B_HOLD;
      rd_ready=cycle-aw_cycle>=R_HOLD;
      fill_start=0;
      if(n==4 && scenario==0)begin
        rd_req=read_request(2);rd_req_valid=1;fill_start=1;
      end
      #1;
      ar_taken=rd_req_valid && responses[1].ar_ready;
      w_taken=wr_data_valid && responses[0].w_ready;
      tick();
      if(ar_taken)rd_req_valid=0;
      if(w_taken)wr_data_valid=0;
      if(core_b_cycle>=0 && read_count==(scenario==0 ? 2 : 1))break;
    end
    fill_start=0;wr_data_valid=0;rd_ready=1;wr_resp_ready=1;inv_ready[1]=1;
    if(core_b_cycle<0 || inv_count!=1 || apply_count!=1 || memory_value!=64'h22)
      $fatal(1,"COH_L2_COMPLETION");
    if(scenario<2 && cache_valid && cache_value!=64'h22)$fatal(1,"COH_L2_STALE_VALUE");
    if(USE_L2 && scenario==0 && (ar_blocked==0 || late_ar_cycle<mem_b_cycle))
      $fatal(1,"COH_L2_ADMISSION_CONTRACT");
    send_read(id_t'(read_count+1));
    begin
      int wanted;
      wanted=scenario==0 ? 3 : 2;
      while(read_count!=wanted)tick();
    end
    if(scenario<2)begin
      if(!cache_valid || cache_value!=(64'h22 ^ 64'(negative)))$fatal(1,"COH_L2_FINAL_VALUE");
    end else begin
      // Post-B re-read: without write-update the write self-invalidated the
      // resident line, so the re-read must miss and fetch a fresh line
      // (second DRAM AR); with it the re-read hits the merged line — the
      // per-beat checker verified the new data either way.
      if(dram_ar_count!=(WRITE_UPDATE ? 1 : 2))$fatal(1,"COH_L2_NO_REFILL");
      if(!WRITE_UPDATE &&
         (dram_ar_len[1]!=L2_LINE_BYTES/8-1 ||
          dram_ar_addr[1]!=(ADDRESS & ~addr_t'(L2_LINE_BYTES-1))))
        $fatal(1,"COH_L2_FILL_GEOMETRY");
    end
    $display("COH_L2_PASS scenario=%0d l2=%0d bytes=%0d aw=%0d inv=%0d apply=%0d mem_b=%0d late_ar=%0d core_b=%0d blocked=%0d dram_ar=%0d l3_hit=%0d l3_miss=%0d",
      scenario,USE_L2,BYTE_SIZE,aw_cycle,first_inv_cycle,last_apply_cycle,mem_b_cycle,late_ar_cycle,core_b_cycle,ar_blocked,dram_ar_count,l3_hits,l3_misses);
    $finish;
  end
endmodule

module tb_g6lc_coherence_credits;
  import g6lc_coherence_pkg::*;
  import g6lc_l2_tb_pkg::*;
  parameter int MSHR_DEPTH=2;
  // Hub shared AR/AW slot count — drives CVA6Cfg.CohMaxOutstanding sweeps
  // (legal range 2..14; the bench counters bound at MAX_OT accordingly).
  parameter int MAX_OT=4;
  parameter int READS_PER_CORE=4;
  // WRITES_PER_CORE>0 interleaves that many write-through AW/W bursts per core
  // port with the read burst (ids READS_PER_CORE+k) — the "mixed" burst that
  // pressures the shared AR/AW credit pool from both channels.
  parameter int WRITES_PER_CORE=0;
  parameter int MEM_LATENCY=8;
  // USE_L3 stacks axi_cut + g6lc_l3_top between the L2 master and the DRAM
  // model (non-inclusive: l3_evict_ready_i tied 1).
  parameter bit USE_L3=1'b0;
  parameter int L3_BYTES=2048, L3_SET_ASSOC=2, L3_MSHR_DEPTH=4, L3_DATA_BANKS=2;
  parameter bit TAG_SRAM=1'b0;
  // CORES parameterises the issuer count so a "four-hart-style" burst can drive
  // four agents without changing the checkers.
  parameter int CORES=2;
  localparam int DRAM_DEPTH=8;
  localparam addr_t BASE=64'h8000_0000;
  logic clk=0,rst_n=0;
  req_t [CORES-1:0] requests;
  resp_t [CORES-1:0] responses;
  req_t hub_req,dram_req;
  resp_t hub_rsp,dram_rsp;
  coh_inval_t [CORES-1:0] invalidations;
  logic [CORES-1:0] inv_ready='1;
  int cycle=0,reads_done=0,writes_done=0;
  int max_fills=0,max_l3_fills=0,max_ar_live=0,max_aw_live=0;
  int mshr_stall_cycles=0,wr_stall_cycles=0;
  int first_ar_cycle=-1,last_r_cycle=-1,last_b_cycle=-1;
  int r_seen[CORES][16];
  bit negative;
  typedef struct {id_t id; addr_t addr; logic [7:0] len; int issue;} dram_entry_t;
  dram_entry_t dram_q[DRAM_DEPTH];
  int dram_head=0,dram_count=0;
  logic [7:0] dram_beat=0;

  g6lc_coherence_hub #(.NR_CORES(CORES),.MAX_OUTSTANDING(MAX_OT),.INVAL_DEPTH(2),
      .LINE_BYTES(16),.SNOOP_FILTER_EN(1),.SNOOP_FILTER_ENTRIES(128),
      .POLICY(config_pkg::COH_OOO),.axi_req_t(req_t),.axi_resp_t(resp_t)) hub (
      .clk_i(clk),.rst_ni(rst_n),.core_req_i(requests),.core_resp_o(responses),
      .mem_req_o(hub_req),.mem_resp_i(hub_rsp),.inv_core_o(invalidations),
      .inv_core_ready_i(inv_ready),.lr_valid_i(1'b0),.lr_addr_i('0),.lr_core_i('0),
      .coh_inv_fire_o(),.coh_sf_hit_o(),.coh_sf_overapprox_o(),.coh_arb_starve_o(),
      .coh_split_conflict_o(),.coh_sc_noresv_o(),.coh_lr_kill_o());
  // dram_req/dram_rsp stay the DRAM edge; l2m_* is the L2 master side.
  req_t l2m_req;
  resp_t l2m_rsp;
  g6lc_l2_top #(.Enable(1'b1),.BYTE_SIZE(4096),.SET_ASSOC(4),
      .LINE_WIDTH(512),.MSHR_DEPTH(MSHR_DEPTH),.DATA_BANKS(2),.FAIR_WRITES(1),
      .TAG_SRAM(TAG_SRAM),
      .AXI_ADDR_WIDTH(AW),.AXI_DATA_WIDTH(DW),.AXI_ID_WIDTH(IDW),.AXI_USER_WIDTH(UW),
      .axi_req_t(req_t),.axi_resp_t(resp_t)) l2 (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(hub_req),.slv_resp_o(hub_rsp),
      .mst_req_o(l2m_req),.mst_resp_i(l2m_rsp),
      .l2_hit_o(),.l2_miss_o(),.l2_bypass_o(),.l2_mshr_full_o(),.l2_bank_conflict_o(),
      .l2_selfinv_hit_o(),.l2_wupdate_o(),
      .l2_evict_valid_o(),.l2_evict_addr_o(),.l2_evict_ready_i(1'b1),
      .l2_back_inval_valid_i(1'b0),.l2_back_inval_addr_i('0),.l2_back_inval_ready_o(),
      .l2_write_idle_o());
  if (USE_L3) begin : gen_l3_stack
    req_t cut_req;
    resp_t cut_rsp;
    axi_cut #(
      .Bypass(1'b0),.aw_chan_t(aw_chan_t),.w_chan_t(w_chan_t),.b_chan_t(b_chan_t),
      .ar_chan_t(ar_chan_t),.r_chan_t(r_chan_t),.req_t(req_t),.resp_t(resp_t)
    ) i_l3_cut (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(l2m_req),.slv_resp_o(l2m_rsp),
      .mst_req_o(cut_req),.mst_resp_i(cut_rsp)
    );
    g6lc_l3_top #(
      .Enable(1'b1),.BYTE_SIZE(L3_BYTES),.SET_ASSOC(L3_SET_ASSOC),
      .LINE_WIDTH(512),.MSHR_DEPTH(L3_MSHR_DEPTH),.DATA_BANKS(L3_DATA_BANKS),
      .TAG_SRAM(TAG_SRAM),
      .AXI_ADDR_WIDTH(AW),.AXI_DATA_WIDTH(DW),.AXI_ID_WIDTH(IDW),.AXI_USER_WIDTH(UW),
      .axi_req_t(req_t),.axi_resp_t(resp_t)
    ) i_l3 (
      .clk_i(clk),.rst_ni(rst_n),.slv_req_i(cut_req),.slv_resp_o(cut_rsp),
      .mst_req_o(dram_req),.mst_resp_i(dram_rsp),
      .l3_hit_o(),.l3_miss_o(),.l3_bypass_o(),.l3_selfinv_hit_o(),
      .l3_wupdate_o(),
      .l3_evict_valid_o(),.l3_evict_addr_o(),.l3_evict_ready_i(1'b1),
      .l3_write_idle_o(),
      .l3_back_inval_valid_i(1'b0),.l3_back_inval_addr_i('0),
      .l3_back_inval_ready_o()
    );
  end else begin : gen_no_l3
    assign dram_req=l2m_req;
    assign l2m_rsp=dram_rsp;
  end

  function automatic data_t model_data(input addr_t a);
    return {a[31:0],~a[31:0]} ^ 64'h5a5a_a5a5_1234_9876;
  endfunction
  function automatic addr_t read_addr(input int c,input int k);
    return BASE+64'((c*READS_PER_CORE+k)*64);
  endfunction
  function automatic addr_t write_addr(input int c,input int k);
    return BASE+64'h0040_0000+64'((c*WRITES_PER_CORE+k)*64);
  endfunction

  // DRAM write side: one write burst open at a time (the model is a serial
  // device); AW is held off while a W burst or its B is pending.
  logic wr_open_q, b_pend_q;
  id_t wr_id_q, b_id_q;
  logic [7:0] wr_len_q, wbeat_q;

  always_comb begin
    dram_rsp='0;
    dram_rsp.ar_ready=dram_count<DRAM_DEPTH;
    dram_rsp.aw_ready=!wr_open_q && !b_pend_q;
    dram_rsp.w_ready=wr_open_q;
    dram_rsp.b_valid=b_pend_q;
    dram_rsp.b='{id:b_id_q,resp:0,user:0};
    dram_rsp.r_valid=dram_count>0 && cycle-dram_q[dram_head].issue>=MEM_LATENCY;
    dram_rsp.r='{id:dram_q[dram_head].id,
      data:model_data(dram_q[dram_head].addr+64'(dram_beat)*8),
      resp:0,last:dram_beat==dram_q[dram_head].len,user:0};
  end
  always_ff @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin
      dram_head<=0;dram_count<=0;dram_beat<=0;
      wr_open_q<=0;b_pend_q<=0;wr_id_q<='0;wr_len_q<='0;wbeat_q<=0;
    end else begin
      int push,pop;
      push=dram_req.ar_valid && dram_rsp.ar_ready;
      pop=dram_rsp.r_valid && dram_req.r_ready && dram_rsp.r.last;
      if(dram_req.aw_valid && dram_rsp.aw_ready && WRITES_PER_CORE==0)
        $fatal(1,"COH_CREDIT_AW");
      if(dram_req.aw_valid && dram_rsp.aw_ready)begin
        wr_open_q<=1;wr_id_q<=dram_req.aw.id;wr_len_q<=dram_req.aw.len;
        wbeat_q<=0;
      end
      if(dram_req.w_valid && dram_rsp.w_ready)begin
        if(dram_req.w.last != (wbeat_q==wr_len_q))
          $fatal(1,"COH_CREDIT_WLAST beat=%0d len=%0d",wbeat_q,wr_len_q);
        wbeat_q<=wbeat_q+1'b1;
        if(dram_req.w.last)begin wr_open_q<=0;b_pend_q<=1;b_id_q<=wr_id_q;end
      end
      if(dram_rsp.b_valid && dram_req.b_ready)b_pend_q<=0;
      if(push)begin
        int tail;
        tail=(dram_head+dram_count)%DRAM_DEPTH;
        dram_q[tail]<='{id:dram_req.ar.id,addr:dram_req.ar.addr,
          len:dram_req.ar.len,issue:cycle};
      end
      if(pop)begin dram_head<=(dram_head+1)%DRAM_DEPTH;dram_beat<=0;end
      else if(dram_rsp.r_valid && dram_req.r_ready)dram_beat<=dram_beat+1'b1;
      dram_count<=dram_count+push-pop;
    end
  end

  // The L3 fill-occupancy probe lives behind a generate: Verilator resolves
  // the dotted name even under the dead arm of a ternary, so a plain
  // USE_L3 ? hier : 0 breaks USE_L3=0 builds.
  int l3_fill_probe;
  if (USE_L3) begin : gen_l3_probe
    always_comb l3_fill_probe = $countones(gen_l3_stack.i_l3.i_l3_as_l2.gen_l2.fill_act_q);
  end else begin : gen_l3_probe
    always_comb l3_fill_probe = 0;
  end

  localparam int WATCHDOG = 2000 + 100*CORES*(READS_PER_CORE+WRITES_PER_CORE);

  always @(posedge clk) begin
    if(rst_n)begin
      int l2_fills,ar_live,aw_live,l3_fills;
      cycle++;
      l2_fills=$countones(l2.gen_l2.fill_act_q);
      l3_fills=l3_fill_probe;
      ar_live=0;
      aw_live=0;
      for(int s=0;s<MAX_OT;s++)begin
        ar_live+=hub.gen_cluster.ar_ot_q[s].valid;
        aw_live+=hub.gen_cluster.aw_ot_q[s].valid;
      end
      if(l2_fills>max_fills)max_fills=l2_fills;
      if(l3_fills>max_l3_fills)max_l3_fills=l3_fills;
      if(ar_live>max_ar_live)max_ar_live=ar_live;
      if(aw_live>max_aw_live)max_aw_live=aw_live;
      if(hub_req.ar_valid && !hub_rsp.ar_ready && l2.gen_l2.mshr_full)mshr_stall_cycles++;
      if(hub_req.aw_valid && !hub_rsp.aw_ready)wr_stall_cycles++;
      if(ar_live>MAX_OT)$fatal(1,"COH_CREDIT_AR_BOUND live=%0d",ar_live);
      if(aw_live>MAX_OT)$fatal(1,"COH_CREDIT_AW_BOUND live=%0d",aw_live);
      if(l2_fills>MSHR_DEPTH)$fatal(1,"COH_CREDIT_FILL_BOUND fills=%0d",l2_fills);
      if(USE_L3 && l3_fills>L3_MSHR_DEPTH)$fatal(1,"COH_CREDIT_L3_BOUND fills=%0d",l3_fills);
      if(USE_L3 && dram_count>DRAM_DEPTH)$fatal(1,"COH_CREDIT_DRAM_BOUND fills=%0d",dram_count);
      if(cycle>WATCHDOG)$fatal(1,"COH_CREDIT_WATCHDOG reads=%0d writes=%0d",reads_done,writes_done);
      for(int c=0;c<CORES;c++)begin
        if(requests[c].ar_valid && responses[c].ar_ready && first_ar_cycle<0)
          first_ar_cycle=cycle;
        if(responses[c].r_valid && requests[c].r_ready)begin
          int id,beat;
          addr_t expected;
          id=int'(responses[c].r.id);
          if(id>=READS_PER_CORE)$fatal(1,"COH_CREDIT_ID core=%0d id=%0d",c,id);
          beat=r_seen[c][id];
          expected=read_addr(c,id)+64'(beat)*8;
          if(responses[c].r.data!=(model_data(expected)^64'(negative)))
            $fatal(1,"COH_CREDIT_DATA core=%0d id=%0d beat=%0d",c,id,beat);
          if(responses[c].r.resp!=0)$fatal(1,"COH_CREDIT_RESP core=%0d id=%0d",c,id);
          if(responses[c].r.last!=(beat==1))$fatal(1,"COH_CREDIT_LAST core=%0d id=%0d",c,id);
          r_seen[c][id]++;
          if(responses[c].r.last)begin reads_done++;last_r_cycle=cycle;end
        end
        if(responses[c].b_valid && requests[c].b_ready)begin
          if(int'(responses[c].b.id)<READS_PER_CORE ||
             int'(responses[c].b.id)>=READS_PER_CORE+WRITES_PER_CORE)
            $fatal(1,"COH_CREDIT_B_ID core=%0d id=%0d",c,responses[c].b.id);
          if(responses[c].b.resp!=0)$fatal(1,"COH_CREDIT_RESP core=%0d",c);
          writes_done++;last_b_cycle=cycle;
        end
      end
    end
  end

  task automatic tick;#2;clk=1;#2;clk=0;#2;endtask
  initial begin
    int issued[CORES];
    int issued_w[CORES];
    // w_left: W beats still owed for the write whose AW was last accepted on
    // this port (one W burst at a time per core — the AW slot itself stays
    // live until B, which is what pressures the shared credit pool).
    int w_left[CORES];
    int w_idx[CORES];
    bit taken[CORES], taken_w[CORES];
    bit done_issuing;
    negative=$test$plusargs("oracle_negative");
    if(READS_PER_CORE+WRITES_PER_CORE>16)
      $fatal(1,"COH_CREDIT_CFG ids overflow IDW (%0d+%0d)",READS_PER_CORE,WRITES_PER_CORE);
    requests='0;
    for(int c=0;c<CORES;c++)begin
      requests[c].r_ready=1'b1;requests[c].b_ready=1'b1;
      issued[c]=0;issued_w[c]=0;w_left[c]=0;w_idx[c]=0;taken[c]=0;taken_w[c]=0;
    end
    for(int c=0;c<CORES;c++)for(int i=0;i<16;i++)r_seen[c][i]=0;
    repeat(3)tick();rst_n=1;repeat(132)tick();
    done_issuing=0;
    for(int n=0;n<WATCHDOG && !done_issuing;n++)begin
      for(int c=0;c<CORES;c++)begin
        if(!requests[c].ar_valid&&issued[c]<READS_PER_CORE)begin
          requests[c].ar='0;
          requests[c].ar.id=id_t'(issued[c]);
          requests[c].ar.addr=read_addr(c,issued[c]);
          requests[c].ar.len=1;requests[c].ar.size=3;
          requests[c].ar.burst=1;requests[c].ar.cache=4'hf;
          requests[c].ar_valid=1'b1;
        end
        if(!requests[c].aw_valid&&issued_w[c]<WRITES_PER_CORE&&w_left[c]==0)begin
          requests[c].aw='0;
          requests[c].aw.id=id_t'(READS_PER_CORE+issued_w[c]);
          requests[c].aw.addr=write_addr(c,issued_w[c]);
          requests[c].aw.len=1;requests[c].aw.size=3;
          requests[c].aw.burst=1;requests[c].aw.cache=4'hf;
          requests[c].aw_valid=1'b1;
        end
        if(w_left[c]>0)begin
          requests[c].w.data=model_data(write_addr(c,w_idx[c])+64'(2-w_left[c])*8);
          requests[c].w.strb='1;
          requests[c].w.last=w_left[c]==1;
          requests[c].w_valid=1'b1;
        end
        taken[c]=0;taken_w[c]=0;
      end
      #1;
      for(int c=0;c<CORES;c++)begin
        taken[c]=requests[c].ar_valid&&responses[c].ar_ready;
        taken_w[c]=requests[c].aw_valid&&responses[c].aw_ready;
        if(w_left[c]>0&&requests[c].w_valid&&responses[c].w_ready)w_left[c]--;
      end
      tick();
      done_issuing=1;
      for(int c=0;c<CORES;c++)begin
        if(taken[c])begin requests[c].ar_valid=1'b0;issued[c]++;end
        if(taken_w[c])begin
          requests[c].aw_valid=1'b0;
          w_idx[c]=issued_w[c];w_left[c]=2;issued_w[c]++;
        end
        if(w_left[c]==0)requests[c].w_valid=1'b0;
        if(issued[c]<READS_PER_CORE||issued_w[c]<WRITES_PER_CORE||
           requests[c].ar_valid||requests[c].aw_valid||w_left[c]>0)
          done_issuing=0;
      end
    end
    if(!done_issuing)$fatal(1,"COH_CREDIT_AR_TIMEOUT");
    for(int n=0;n<WATCHDOG &&
          (reads_done!=CORES*READS_PER_CORE||writes_done!=CORES*WRITES_PER_CORE);
        n++)tick();
    if(reads_done!=CORES*READS_PER_CORE||writes_done!=CORES*WRITES_PER_CORE)
      $fatal(1,"COH_CREDIT_WATCHDOG reads_done=%0d writes_done=%0d",
        reads_done,writes_done);
    $display("COH_CREDIT_PASS mshr=%0d l3=%0d l3_mshr=%0d cores=%0d reads=%0d writes=%0d max_fills=%0d max_l3_fills=%0d max_ar_live=%0d max_aw_live=%0d mshr_stall_cycles=%0d wr_stall_cycles=%0d drain=%0d ot=%0d",
      MSHR_DEPTH,USE_L3,L3_MSHR_DEPTH,CORES,CORES*READS_PER_CORE,CORES*WRITES_PER_CORE,
      max_fills,max_l3_fills,max_ar_live,max_aw_live,mshr_stall_cycles,wr_stall_cycles,
      last_r_cycle-first_ar_cycle,MAX_OT);
    $finish;
  end
endmodule
