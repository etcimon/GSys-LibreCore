// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_checkpoint_route;
  import g6lc_storamic_pkg::*;
  parameter bit Enabled = 1;
  parameter int unsigned MasterCount = 3;
  parameter bit UseMux = 0, SpillRequests = 0, UseXbar = 0;
  // NativeProfile: crossbar dimensions match the real ariane xbar (3 slave
  // ports, 4-bit local IDs -> 6-bit tagged, MaxTrans 8, NO_LATENCY, UniqueIds
  // 0, NoMstPorts >= native NB_MST) and the bench drives all three requester
  // ports concurrently with adversarial port-1/port-2 traffic.
  parameter bit NativeProfile = 0;
  parameter int unsigned NativeMstPorts = 16;
  parameter int unsigned StoramicIdx = 13;
  localparam int unsigned IdW = 6;
  // axi_pkg::CACHE_MODIFIABLE — the only cache encoding the qualified CPU
  // emits for uncached scalar data (axi_shim.sv). The route admits exactly
  // this value; every other cache field is refused.
  localparam logic [3:0] DataCache = axi_pkg::CACHE_MODIFIABLE;
  localparam logic [63:0] Base = 64'h5000_0000;
  `include "route-axi-types.svh"
  `include "route-local-types.svh"
  logic clk = 0, rst_n = 0, policy_ready = 1;
  logic [31:0] epoch = 7;
  logic aw_valid = 0, w_valid = 0, ar_valid = 0, b_ready = 0, r_ready = 0;
  aw_t aw_header;
  ar_t ar_header;
  logic [31:0] cookie = 32'h1234;
  logic [3:0] strobe = 4'hF;
  req_t req;
  resp_t resp;
  req_t routed_req;
  resp_t routed_resp;
  // NativeProfile drives all three crossbar slave ports concurrently through
  // these per-port bundles instead of the single selected_master request.
  local_req_t [2:0] native_req;
  local_resp_t [2:0] native_resp;
  int selected_master = 0;
  axil_req_t ctrl, service_req, virtio;
  axil_resp_t ctrl_resp, service_resp;
  logic service_enable, aw_auth, ar_auth, hold_policy;
  logic aw_src_ok, ar_src_ok;
  logic block_aw = 0, block_w = 0, block_ar = 0;
  logic command, authorized;
  logic [31:0] command_cookie;
  int checks = 0, grants = 0, w_transfers = 0;
  bit negative;
  assign req = '{aw: aw_header, aw_valid: aw_valid,
      w: '{data: {cookie, cookie}, strb: {strobe, strobe}, last: 1'b1, user: 1'b0},
      w_valid: w_valid, b_ready: b_ready, ar: ar_header, ar_valid: ar_valid, r_ready: r_ready};
  if (UseMux) begin : gen_mux
    local_req_t [2:0] inputs;
    local_resp_t [2:0] outputs;
    int rogue;
    always_comb begin
      if (NativeProfile) begin
        inputs = native_req;
      end else begin
      rogue = selected_master == 2 ? 1 : 2;
      inputs = '0;
      inputs[selected_master].aw = local_aw_t'(req.aw);
      inputs[selected_master].aw_valid = req.aw_valid;
      inputs[selected_master].w = local_w_t'(req.w);
      inputs[selected_master].w_valid = req.w_valid;
      inputs[selected_master].b_ready = req.b_ready;
      inputs[selected_master].ar = local_ar_t'(req.ar);
      inputs[selected_master].ar_valid = req.ar_valid;
      inputs[selected_master].r_ready = req.r_ready;
      // An untrusted peer offers W without AW throughout. The mux's AW-owner
      // FIFO, not this fixture, must prevent those bytes becoming a CPU command.
      inputs[rogue].w = '{data: 64'hBAD0_BAD0_BAD0_BAD0, strb: 8'hFF, last: 1'b1, user: 1'b1};
      inputs[rogue].w_valid = 1'b1;
      end
    end
    always_comb begin
      resp = '{aw_ready: outputs[selected_master].aw_ready,
          w_ready: outputs[selected_master].w_ready, b: b_t'(outputs[selected_master].b),
          b_valid: outputs[selected_master].b_valid, ar_ready: outputs[selected_master].ar_ready,
          r: r_t'(outputs[selected_master].r), r_valid: outputs[selected_master].r_valid};
    end
    if (UseXbar) begin : gen_xbar
      // NativeProfile reproduces the ariane_testharness crossbar dimensions:
      // NoSlvPorts = ariane_soc::NrSlaves (3), AxiIdWidthSlvPorts =
      // ariane_axi::IdWidth (4 -> 6-bit port-tagged master IDs), MaxTrans 8,
      // NO_LATENCY, UniqueIds 0, NoMstPorts >= native NB_MST. The Storamic
      // control window routes to master port StoramicIdx; every other master
      // port must stay idle. The legacy profile keeps 2 master ports with the
      // route on 0 and a decoy window on 1.
      localparam int unsigned EffMstPorts = NativeProfile ? NativeMstPorts : 2;
      localparam int unsigned EffStoramicIdx = NativeProfile ? StoramicIdx : 0;
      localparam int unsigned EffAddrRules = NativeProfile ? 1 : 2;
      localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts: 3, NoMstPorts: EffMstPorts, MaxMstTrans: 8, MaxSlvTrans: 8,
        FallThrough: 1'b0,
        LatencyMode: (NativeProfile || !SpillRequests) ? axi_pkg::NO_LATENCY
                                                     : axi_pkg::CUT_ALL_AX,
        AxiIdWidthSlvPorts: 4, AxiIdUsedSlvPorts: 4, UniqueIds: 1'b0,
        AxiAddrWidth: 64, AxiDataWidth: 64, NoAddrRules: EffAddrRules
      };
      req_t [EffMstPorts-1:0] targets;
      resp_t [EffMstPorts-1:0] responses;
      assign routed_req = targets[EffStoramicIdx];
      assign responses[EffStoramicIdx] = routed_resp;
      // Every non-Storamic master port is undriven: no request may decode to
      // it. For the legacy profile this is exactly the old responses[1]='0 /
      // decoy assertion; for the native profile it covers all 15 idle ports.
      for (genvar gi = 0; gi < EffMstPorts; gi++) begin : gen_idle_resp
        if (gi != EffStoramicIdx) assign responses[gi] = '0;
      end
      // addr_map_i is an unpacked array sized by NoAddrRules (=EffAddrRules):
      // native binds one Storamic rule, the legacy profile adds a decoy window.
      // A single ternary cannot satisfy both arities, so each gets its own
      // correctly-sized literal under a nested generate conditional.
      if (NativeProfile) begin : g_native_xbar
          axi_xbar #(
            .Cfg(XbarCfg), .ATOPs(1'b1),
            .slv_aw_chan_t(local_aw_t), .mst_aw_chan_t(aw_t), .w_chan_t(local_w_t),
            .slv_b_chan_t(local_b_t), .mst_b_chan_t(b_t),
            .slv_ar_chan_t(local_ar_t), .mst_ar_chan_t(ar_t),
            .slv_r_chan_t(local_r_t), .mst_r_chan_t(r_t),
            .slv_req_t(local_req_t), .slv_resp_t(local_resp_t),
            .mst_req_t(req_t), .mst_resp_t(resp_t), .rule_t(axi_pkg::xbar_rule_64_t)
          ) crossbar (
            .clk_i(clk), .rst_ni(rst_n), .test_i(1'b0),
            .slv_ports_req_i(inputs), .slv_ports_resp_o(outputs),
            .mst_ports_req_o(targets), .mst_ports_resp_i(responses),
            .addr_map_i('{ '{idx: EffStoramicIdx, start_addr: Base,
                end_addr: Base + 64'h10_0000} }),
            .en_default_mst_port_i('0), .default_mst_port_i('0)
          );
        end else begin : g_legacy_xbar
          axi_xbar #(
            .Cfg(XbarCfg), .ATOPs(1'b1),
            .slv_aw_chan_t(local_aw_t), .mst_aw_chan_t(aw_t), .w_chan_t(local_w_t),
            .slv_b_chan_t(local_b_t), .mst_b_chan_t(b_t),
            .slv_ar_chan_t(local_ar_t), .mst_ar_chan_t(ar_t),
            .slv_r_chan_t(local_r_t), .mst_r_chan_t(r_t),
            .slv_req_t(local_req_t), .slv_resp_t(local_resp_t),
            .mst_req_t(req_t), .mst_resp_t(resp_t), .rule_t(axi_pkg::xbar_rule_64_t)
          ) crossbar (
            .clk_i(clk), .rst_ni(rst_n), .test_i(1'b0),
            .slv_ports_req_i(inputs), .slv_ports_resp_o(outputs),
            .mst_ports_req_o(targets), .mst_ports_resp_i(responses),
            .addr_map_i('{ '{idx: 1, start_addr: 64'h6000_0000,
                end_addr: 64'h6010_0000},
              '{idx: EffStoramicIdx, start_addr: Base,
                end_addr: Base + 64'h10_0000} }),
            .en_default_mst_port_i('0), .default_mst_port_i('0)
          );
        end
      // Export the full per-port response bundle for the native sequence.
      assign native_resp = outputs;
      always @(posedge clk) if (rst_n) begin
        for (int mi = 0; mi < EffMstPorts; mi++) begin
          if (mi != int'(EffStoramicIdx))
            assert(!targets[mi].aw_valid && !targets[mi].ar_valid) else
              $fatal(1, "CHECKPOINT_ROUTE_FAIL idle-master-port");
        end
      end
    end else begin : gen_mux_only
    axi_mux #(
      .SlvAxiIDWidth(4), .NoSlvPorts(3), .MaxWTrans(4), .FallThrough(1'b0),
      .SpillAw(SpillRequests), .SpillW(SpillRequests), .SpillAr(SpillRequests),
      .SpillB(1'b0), .SpillR(1'b0),
      .slv_aw_chan_t(local_aw_t), .mst_aw_chan_t(aw_t), .w_chan_t(local_w_t),
      .slv_b_chan_t(local_b_t), .mst_b_chan_t(b_t),
      .slv_ar_chan_t(local_ar_t), .mst_ar_chan_t(ar_t),
      .slv_r_chan_t(local_r_t), .mst_r_chan_t(r_t),
      .slv_req_t(local_req_t), .slv_resp_t(local_resp_t),
      .mst_req_t(req_t), .mst_resp_t(resp_t)
    ) fabric (
      .clk_i(clk), .rst_ni(rst_n), .test_i(1'b0),
      .slv_reqs_i(inputs), .slv_resps_o(outputs), .mst_req_o(routed_req), .mst_resp_i(routed_resp)
    );
    end
    always @(posedge clk) if (rst_n && !NativeProfile) begin
      if (routed_req.aw_valid && routed_resp.aw_ready)
        assert(routed_req.aw.id[5:4] == 2'(selected_master)) else
          $fatal(1, "CHECKPOINT_ROUTE_FAIL physical-aw-prefix");
      if (routed_req.ar_valid && routed_resp.ar_ready)
        assert(routed_req.ar.id[5:4] == 2'(selected_master)) else
          $fatal(1, "CHECKPOINT_ROUTE_FAIL physical-ar-prefix");
      assert(!outputs[rogue].w_ready) else
        $fatal(1, "CHECKPOINT_ROUTE_FAIL peer-w-without-aw");
      for (int p = 0; p < 3; p++) if (p != selected_master)
        assert(!outputs[p].b_valid && !outputs[p].r_valid) else
          $fatal(1, "CHECKPOINT_ROUTE_FAIL response-owner");
      if (command && authorized)
        assert(command_cookie == cookie) else
          $fatal(1, "CHECKPOINT_ROUTE_FAIL peer-cookie-injection");
    end
  end else begin : gen_direct
    assign routed_req = req;
    assign resp = routed_resp;
  end
  always_comb begin
    service_req = ctrl;
    service_req.aw_valid = ctrl.aw_valid && !block_aw;
    service_req.w_valid = ctrl.w_valid && !block_w;
    service_req.ar_valid = ctrl.ar_valid && !block_ar;
    ctrl_resp = service_resp;
    ctrl_resp.aw_ready = service_resp.aw_ready && !block_aw;
    ctrl_resp.w_ready = service_resp.w_ready && !block_w;
    ctrl_resp.ar_ready = service_resp.ar_ready && !block_ar;
  end
  g6lc_storamic_checkpoint_route #(
    .Enable(Enabled), .LocalIdWidth(4), .NumMasters(MasterCount), .TrustedMaster(0),
    .IdWidth(IdW), .Base(Base), .req_t(req_t), .resp_t(resp_t)
  ) route (
    .clk_i(clk), .rst_ni(rst_n), .req_i(routed_req), .resp_o(routed_resp),
    .policy_ready_i(policy_ready), .policy_epoch_i(epoch),
    .ctrl_req_o(ctrl), .ctrl_resp_i(ctrl_resp), .vctrl_req_o(virtio), .vctrl_resp_i('0),
    .service_enable_o(service_enable), .aw_authorized_o(aw_auth),
    .ar_authorized_o(ar_auth), .policy_hold_o(hold_policy),
    .aw_source_ok_o(aw_src_ok), .ar_source_ok_o(ar_src_ok)
  );
  g6lc_storamic_checkpoint_service service (
    .clk_i(clk), .rst_ni(rst_n), .req_i(service_req), .resp_o(service_resp),
    .service_enable_i(service_enable), .aw_authorized_i(aw_auth),
    .command_admit_i(1'b1), .policy_hold_o(),
    .ar_authorized_i(ar_auth), .policy_epoch_i(epoch),
    .command_valid_o(command), .command_restore_o(), .command_authorized_o(authorized),
    .command_cookie_o(command_cookie), .command_ready_i(1'b1),
    .result_valid_i(1'b0), .result_cookie_i('0), .result_i(CP_OK), .result_ready_o(),
    .initialized_i(1'b1), .busy_i(1'b0), .recovery_locked_i(1'b0), .metadata_ok_i(1'b1),
    .protection_ok_i(1'b1), .checkpoint_valid_i(1'b1), .checkpoint_generation_i(64'hAA),
    .issue_event_o(), .refuse_event_o(), .revoke_event_o()
  );
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin grants <= 0; w_transfers <= 0; end
    else begin
      if (command && authorized) grants <= grants + 1;
      if (w_valid && resp.w_ready) w_transfers <= w_transfers + 1;
    end
  end
  task automatic tick; #2; clk = 1; #2; clk = 0; #2; endtask
  task automatic check(input bit value, input string label);
    checks++;
    if (!value) $fatal(1, "CHECKPOINT_ROUTE_FAIL %s", label);
  endtask
  function automatic aw_t address_write(input int master, input logic [2:0] prot,
                                        input logic [63:0] address = Base);
    return '{id: IdW'((master << 4) | 9), addr: address, size: 3'd2, burst: 2'b01,
             cache: DataCache, prot: prot, default: '0};
  endfunction
  function automatic ar_t address_read(input int master, input logic [2:0] prot);
    return '{id: IdW'((master << 4) | 3), addr: Base + 64'h10, size: 3'd2, burst: 2'b01,
             cache: DataCache, prot: prot, default: '0};
  endfunction
  task automatic send_aw;
    if (UseMux) selected_master = int'(aw_header.id[5:4]);
    aw_valid = 1; #1;
    for (int n = 0; n < 200 && !resp.aw_ready; n++) tick();
    check(resp.aw_ready, "aw-accept"); tick(); aw_valid = 0;
    for (int n = 0; n < 8 && !hold_policy; n++) tick();
    check(hold_policy, "aw-ownership");
  endtask
  task automatic finish_write(input logic [1:0] expected, input int old_grants,
                              input logic [IdW-1:0] id = 6'h09,
                              input bit w_already_accepted = 0,
                              input bit expect_src = 0);
    if (!w_already_accepted) begin
      w_valid = 1; #1;
      for (int n = 0; n < 200 && !resp.w_ready; n++) tick();
      check(resp.w_ready, "w-accept"); tick();
    end else check(w_transfers != 0, "earlier-w-accept");
    w_valid = 0;
    for (int n = 0; n < 200 && !resp.b_valid; n++) tick();
    check(resp.b_valid && resp.b.resp == expected &&
        resp.b.id == (UseMux ? {2'b00, id[3:0]} : id), "b-response");
    repeat (5) begin
      tick();
      check(resp.b_valid && resp.b.resp == expected && hold_policy, "held-b-and-policy");
      check(aw_src_ok == expect_src, "aw-source-ok");
    end
    check(grants == old_grants + int'(expected == 0), "command-once");
    b_ready = 1; tick(); b_ready = 0; tick();
    check(!hold_policy, "write-owner-retired");
    check(!aw_src_ok, "aw-source-ok-retired");
  endtask
  task automatic send_ar;
    if (UseMux) selected_master = int'(ar_header.id[5:4]);
    ar_valid = 1; #1;
    for (int n = 0; n < 200 && !resp.ar_ready; n++) tick();
    check(resp.ar_ready, "ar-accept"); tick(); ar_valid = 0;
    for (int n = 0; n < 8 && !hold_policy; n++) tick();
    check(hold_policy, "ar-ownership");
  endtask
  task automatic finish_read(input logic [1:0] expected, input logic [IdW-1:0] id,
                             input bit expect_src = 0);
    for (int n = 0; n < 200 && !resp.r_valid; n++) tick();
    check(resp.r_valid && resp.r.resp == expected &&
          resp.r.id == (UseMux ? {2'b00, id[3:0]} : id) && resp.r.last,
          "r-response");
    check(resp.r.data == (expected == 0 ? 64'h0000_00F1_0000_00F1 : 0), "r-content");
    repeat (5) begin
      tick();
      check(resp.r_valid && resp.r.resp == expected && hold_policy, "held-r-and-policy");
      check(ar_src_ok == expect_src, "ar-source-ok");
    end
    r_ready = 1; tick(); r_ready = 0; tick();
    check(!hold_policy, "read-owner-retired");
    check(!ar_src_ok, "ar-source-ok-retired");
  endtask
  // ================= NativeProfile: concurrent 3-port adversarial drive ======
  // Every requester port presents byte-identical channel fields for the same
  // logical access — same 4-bit local ID, prot=001, cache=DataCache, in-window
  // word-aligned address — so only the crossbar port prefix (id[5:4]) separates
  // trusted port 0 from adversarial ports 1/2. Writes and reads are offered on
  // all three ports concurrently (AW/W and AR/R channels active together). The
  // ctrl bridge is single-write- and single-read-outstanding, so each port's
  // writes are pumped sequentially (one unacknowledged write per port, <=3 in
  // flight, <= MaxMstTrans=8) and reads are serviced in one combined AR+R loop;
  // every B/R must return to the originating port carrying the original local ID.
  localparam int unsigned WPP = 2;  // writes per port -> 6 outstanding (<=8)
  function automatic local_aw_t n_aw(input logic [3:0] id, input logic [63:0] addr);
    return '{id: id, addr: addr, len: 8'h0, size: 3'd2, burst: 2'b01,
             lock: 1'b0, cache: DataCache, prot: 3'b001, qos: 4'h0,
             region: 4'h0, atop: 6'h0, user: 1'b0};
  endfunction
  function automatic local_ar_t n_ar(input logic [3:0] id, input logic [63:0] addr);
    return '{id: id, addr: addr, len: 8'h0, size: 3'd2, burst: 2'b01,
             lock: 1'b0, cache: DataCache, prot: 3'b001, qos: 4'h0,
             region: 4'h0, user: 1'b0};
  endfunction
  function automatic local_w_t n_w(input logic [63:0] data);
    return '{data: data, strb: 8'hFF, last: 1'b1, user: 1'b0};
  endfunction
  // write j on any port: local id 9+j. Every requester drives the SAME command
  // offset (Base+0x00, the issue-command register) and the SAME {cookie,cookie}
  // payload the scalar profiles use, so the only field separating trusted port
  // 0 from adversarial ports 1/2 is the crossbar-inserted ID prefix. The service
  // decodes writes only at Base+0x00/+0x04 (issue/restore) and +0x08 (result);
  // any other in-window offset is a SLVERR decode, which is not what this bench
  // exercises.
  function automatic logic [3:0] wr_id(input int j);
    return 4'(32'h9 + j);
  endfunction
  function automatic logic [63:0] wr_addr(input int p, input int j);
    return Base;
  endfunction
  function automatic logic [63:0] wr_data(input int p, input int j);
    return {cookie, cookie};
  endfunction
  function automatic logic [63:0] rd_addr(input int p);
    return Base + 64'h10;
  endfunction
  task automatic native_adversarial;
    int cur[3], b_mask[3], b_j[3];
    bit awok[3], wok[3], awsub[3], wsub[3], bpend[3];
    bit [2:0] r_done, ar_done;
    int j, p, spin;
    logic [1:0] exp_resp;
    localparam int unsigned FULL = (1 << WPP) - 1;
    // Define every slave-port request bundle before reset so the crossbar
    // never samples X on slv_ports_req_i.
    for (p = 0; p < 3; p++) native_req[p] = '0;
    repeat (3) tick(); rst_n = 1; tick();
    // Per-port SEQUENTIAL write pump: each port drives AW+W for write j, waits
    // for that write's B, then issues j+1. At most one write per port is ever
    // unacknowledged, so <=3 writes are in flight; the single-write-outstanding
    // ctrl bridge drains them one at a time via aw_ready backpressure while the
    // crossbar preserves each port's tagged local ID. B/R must return per-port.
    for (p = 0; p < 3; p++) begin
      cur[p] = 0; b_mask[p] = 0; b_j[p] = 0;
      awok[p] = 0; wok[p] = 0; awsub[p] = 0; wsub[p] = 0; bpend[p] = 0;
      native_req[p].b_ready = 1'b0;
      native_req[p].aw = n_aw(wr_id(0), wr_addr(p, 0)); native_req[p].aw_valid = 1'b1;
      native_req[p].w = n_w(wr_data(p, 0)); native_req[p].w_valid = 1'b1;
    end
    spin = 0;
    while ((b_mask[0] != FULL || b_mask[1] != FULL ||
            b_mask[2] != FULL) && spin < 50000) begin
      spin++;
      for (p = 0; p < 3; p++) begin
        exp_resp = (Enabled && p == 0) ? 2'b00 : 2'b10;
        // Drive AW/W for the current write until both channels handshake.
        if (cur[p] < WPP) begin
          native_req[p].aw_valid = !awok[p];
          native_req[p].w_valid = !wok[p];
          if (!awok[p] && native_req[p].aw_valid && native_resp[p].aw_ready)
            awsub[p] = 1'b1;
          if (!wok[p] && native_req[p].w_valid && native_resp[p].w_ready)
            wsub[p] = 1'b1;
        end else begin
          native_req[p].aw_valid = 1'b0; native_req[p].w_valid = 1'b0;
        end
        if (!bpend[p] && native_resp[p].b_valid) begin
          j = int'(native_resp[p].b.id) - 9;
          check(j == cur[p] && j >= 0 && j < WPP && !b_mask[p][j] &&
                native_resp[p].b.resp == exp_resp, "n-b-response");
          native_req[p].b_ready = 1'b1; bpend[p] = 1'b1; b_j[p] = j;
        end
      end
      tick();
      for (p = 0; p < 3; p++) begin
        if (awsub[p]) begin awok[p] = 1'b1; awsub[p] = 1'b0; end
        if (wsub[p])  begin wok[p]  = 1'b1; wsub[p]  = 1'b0; end
        if (bpend[p]) begin
          native_req[p].b_ready = 1'b0;
          if (b_j[p] >= 0 && b_j[p] < WPP)
            b_mask[p] = b_mask[p] | (1 << b_j[p]);
          bpend[p] = 1'b0;
          // Advance past every write whose B has now returned, re-arming AW/W.
          while (cur[p] < WPP && b_mask[p][cur[p]]) begin
            cur[p]++;
            awok[p] = 1'b0; wok[p] = 1'b0;
            if (cur[p] < WPP) begin
              native_req[p].aw = n_aw(wr_id(cur[p]), wr_addr(p, cur[p]));
              native_req[p].w = n_w(wr_data(p, cur[p]));
            end
          end
        end
      end
    end
    check(spin < 50000, "n-write-timeout");
    // Only port 0's WPP writes are authorized commands (Enabled=1); the
    // adversarial ports are refused. grants counts issued commands.
    check(grants == (Enabled ? WPP : 0), "n-writes-granted");
    // Read phase: one AR per port. The ctrl bridge is single-read-outstanding
    // (ar_ready only in RIdle), so AR acceptance and the R handshake must be
    // serviced in the SAME loop — waiting for every ar_ready before any r_ready
    // deadlocks once the first read's R is pending and blocks the bridge. The
    // crossbar preserves each port's tagged local ID on the returned R.
    ar_done = '0; r_done = '0;
    for (p = 0; p < 3; p++) begin
      native_req[p].aw_valid = 1'b0; native_req[p].w_valid = 1'b0;
      native_req[p].ar = n_ar(4'h3, rd_addr(p));
      native_req[p].ar_valid = 1'b1;
      native_req[p].r_ready = 1'b0;
      awsub[p] = 0; bpend[p] = 0;
    end
    spin = 0;
    while (r_done != 3'b111 && spin < 50000) begin
      spin++;
      for (p = 0; p < 3; p++) begin
        exp_resp = (Enabled && p == 0) ? 2'b00 : 2'b10;
        if (!ar_done[p] && native_resp[p].ar_ready) awsub[p] = 1'b1;
        if (!r_done[p] && !bpend[p] && native_resp[p].r_valid) begin
          check(native_resp[p].r.id == 4'h3 && native_resp[p].r.resp == exp_resp &&
                native_resp[p].r.last &&
                native_resp[p].r.data == (exp_resp == 0 ? 64'h0000_00F1_0000_00F1 : 0),
                "n-r-response");
          native_req[p].r_ready = 1'b1; bpend[p] = 1'b1;
        end
      end
      tick();
      for (p = 0; p < 3; p++) begin
        if (awsub[p]) begin
          awsub[p] = 1'b0; ar_done[p] = 1'b1; native_req[p].ar_valid = 1'b0;
        end
        if (bpend[p]) begin
          bpend[p] = 1'b0; r_done[p] = 1'b1; native_req[p].r_ready = 1'b0;
        end
      end
    end
    check(r_done == 3'b111, "n-read-timeout");
    $display("CHECKPOINT_ROUTE_PASS checks=%0d enabled=%0d mux=1 spill=0 xbar=1 native=1",
             checks, Enabled);
    $finish;
  endtask
  initial begin
    int before_grants, before_w;
    logic [1:0] expected;
    bit expect_src;
    aw_t header;
    if (!NativeProfile) begin : seq_std
    negative = $test$plusargs("oracle_negative");
    aw_header = address_write(0, 1); ar_header = address_read(0, 1);
    repeat (3) tick(); rst_n = 1; tick();
    for (int master = 0; master < (UseMux ? 3 : 4); master++) begin
      for (int prot = 0; prot < 8; prot++) begin
        expected = Enabled && master == 0 && prot == 1 ? 2'b00 : 2'b10;
        // source_ok is the pure structural candidate: legal shape + DataCache +
        // trusted prefix + prot==001, independent of Enable/policy/epoch. With
        // Enabled=0 a port-0/prot-001 packet still reports source_ok=1 while
        // staying unauthorized (B=SLVERR) — the decoupling the stage proves.
        expect_src = master == 0 && prot == 1;
        before_grants = grants;
        aw_header = address_write(master, 3'(prot));
        send_aw(); finish_write(expected, before_grants, IdW'((master << 4) | 9),
                                0, expect_src);
        ar_header = address_read(master, 3'(prot));
        send_ar(); finish_read(expected, IdW'((master << 4) | 3), expect_src);
      end
    end
    // Unaccepted live headers must neither promote nor revoke the owned packet.
    before_grants = grants; aw_header = address_write(2, 1);
    send_aw(); aw_header = address_write(0, 1);
    finish_write(2, before_grants, 6'h29);
    before_grants = grants; aw_header = address_write(0, 1);
    send_aw(); aw_header = address_write(2, 1);
    finish_write(Enabled ? 0 : 2, before_grants, 6'h09, 0, 1);
    // W can be offered first but is not paired until the bridge accepts AW.
    before_grants = grants; before_w = w_transfers; w_valid = 1; tick();
    check(!resp.w_ready, "w-before-aw-retained");
    aw_header = address_write(0, 1); send_aw();
    finish_write(Enabled ? 0 : 2, before_grants, 6'h09, w_transfers != before_w, 1);
    // Delay downstream AW; policy must be captured at upstream acceptance.
    before_grants = grants; block_aw = 1; aw_header = address_write(0, 1);
    send_aw(); epoch = 8; tick(); epoch = 7; tick(); block_aw = 0;
    finish_write(2, before_grants, 6'h09, 0, 1);
    before_grants = grants; block_aw = 1;
    send_aw(); policy_ready = 0; tick(); policy_ready = 1; tick(); block_aw = 0;
    finish_write(2, before_grants, 6'h09, 0, 1);
    // The independent AR owner has the same sticky loss/ABA rule.
    block_ar = 1; ar_header = address_read(0, 1); send_ar();
    epoch = 9; tick(); epoch = 7; tick(); block_ar = 0;
    finish_read(2, 6'h03, 1);
    block_ar = 1; send_ar(); policy_ready = 0; tick();
    policy_ready = 1; tick(); block_ar = 0; finish_read(2, 6'h03, 1);
    // Locks, cached packets, subword/misaligned requests and ATOPs are not commands.
    // cache must equal DataCache exactly: cache==0 (the old bench encoding),
    // alloc-bit and bufferable variants are all refused as non-candidates.
    for (int malformed = 0; malformed < 12; malformed++) begin
      header = address_write(0, 1);
      case (malformed)
        0: header.lock = 1;
        1: header.cache = 4'hF;
        2: header.size = 1;
        3: header.addr = Base + 1;
        4: header.atop = 1;
        5: header.burst = 2;
        6: strobe = 4'h7;
        7: header.cache = 4'h0;
        8: header.cache = 4'h1;
        9: header.cache = 4'h3;
        10: header.cache = 4'h6;
        11: header.cache = 4'hA;
      endcase
      // source_ok is the pure AW structural candidate: case 6 corrupts only the
      // W strobe (payload), leaving a valid AW source packet -> source_ok=1 while
      // the write is still refused downstream (B=SLVERR). Every other case breaks
      // an AW field, so it is not a source candidate.
      before_grants = grants; aw_header = header; send_aw();
      finish_write(2, before_grants, 6'h09, 0, malformed == 6);
      strobe = 4'hF;
    end
    // Reads share the identical candidate rule: a cache==0 AR is refused too.
    before_grants = grants; ar_header = address_read(0, 1); ar_header.cache = 4'h0;
    send_ar(); finish_read(2, 6'h03, 0);
    before_grants = grants; ar_header = address_read(0, 1); ar_header.cache = 4'h3;
    send_ar(); finish_read(2, 6'h03, 0);
    // Provider recovery allows only a new packet, never resurrects an owned one.
    before_grants = grants; aw_header = address_write(0, 1); send_aw();
    finish_write(Enabled ? 0 : 2, before_grants, 6'h09, 0, 1);
    check(!negative, "negative-oracle");
    $display("CHECKPOINT_ROUTE_PASS checks=%0d enabled=%0d mux=%0d spill=%0d xbar=%0d",
             checks, Enabled, UseMux, SpillRequests, UseXbar);
    $finish;
    end
  end
  initial begin
    if (NativeProfile) native_adversarial();
  end
  initial begin #1000000; $fatal(1, "CHECKPOINT_ROUTE_TIMEOUT"); end
endmodule
