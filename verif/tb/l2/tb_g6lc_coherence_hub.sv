// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_coherence_hub;
  import g6lc_coherence_pkg::*;
  import g6lc_l2_tb_pkg::*;
  parameter int unsigned OT = 4;
  logic clk = 0, rst_n = 0;
  req_t [1:0] core_req;
  resp_t [1:0] core_rsp;
  req_t memory_req;
  resp_t memory_rsp;
  coh_inval_t [1:0] invalidations;
  logic [1:0] invalidation_ready;
  bit negative;
  int scenario;

  g6lc_coherence_hub #(
    .NR_CORES(2), .MAX_OUTSTANDING(OT), .INVAL_DEPTH(2),
    .SNOOP_FILTER_EN(0), .SNOOP_FILTER_ENTRIES(4),
    .POLICY(config_pkg::COH_BROADCAST), .AXI_STARVE_LIMIT(16),
    .axi_req_t(req_t), .axi_resp_t(resp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .core_req_i(core_req), .core_resp_o(core_rsp),
    .mem_req_o(memory_req), .mem_resp_i(memory_rsp),
    .inv_core_o(invalidations), .inv_core_ready_i(invalidation_ready),
    .lr_valid_i(1'b0), .lr_addr_i('0), .lr_core_i('0),
    .coh_inv_fire_o(), .coh_sf_hit_o(), .coh_sf_overapprox_o(),
    .coh_arb_starve_o(), .coh_split_conflict_o(), .coh_sc_fail_o(), .coh_lr_kill_o()
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
    for (int c = 0; c < 2; c++) begin
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
      default: $fatal(1, "HUB_SCENARIO");
    endcase
    $display("HUB_PASS scenario=%0d", scenario);
    $finish;
  end
endmodule
