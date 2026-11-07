// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
module tb_g6lc_storamic_checkpoint_route;
  import g6lc_storamic_pkg::*;
  parameter bit Enabled = 1;
  parameter int unsigned MasterCount = 3;
  parameter bit UseMux = 0, SpillRequests = 0, UseXbar = 0;
  localparam int unsigned IdW = 6;
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
  int selected_master = 0;
  axil_req_t ctrl, service_req, virtio;
  axil_resp_t ctrl_resp, service_resp;
  logic service_enable, aw_auth, ar_auth, hold_policy;
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
    always_comb begin
      resp = '{aw_ready: outputs[selected_master].aw_ready,
          w_ready: outputs[selected_master].w_ready, b: b_t'(outputs[selected_master].b),
          b_valid: outputs[selected_master].b_valid, ar_ready: outputs[selected_master].ar_ready,
          r: r_t'(outputs[selected_master].r), r_valid: outputs[selected_master].r_valid};
    end
    if (UseXbar) begin : gen_xbar
      localparam axi_pkg::xbar_cfg_t XbarCfg = '{
        NoSlvPorts: 3, NoMstPorts: 2, MaxMstTrans: 8, MaxSlvTrans: 8,
        FallThrough: 1'b0,
        LatencyMode: SpillRequests ? axi_pkg::CUT_ALL_AX : axi_pkg::NO_LATENCY,
        AxiIdWidthSlvPorts: 4, AxiIdUsedSlvPorts: 4, UniqueIds: 1'b0,
        AxiAddrWidth: 64, AxiDataWidth: 64, NoAddrRules: 2
      };
      req_t [1:0] targets;
      resp_t [1:0] responses;
      assign routed_req = targets[0];
      assign responses[0] = routed_resp;
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
        .addr_map_i('{
          '{idx: 1, start_addr: 64'h6000_0000, end_addr: 64'h6010_0000},
          '{idx: 0, start_addr: Base, end_addr: Base + 64'h10_0000}}),
        .en_default_mst_port_i('0), .default_mst_port_i('0)
      );
      // This profile targets only page-0/page-1 control routing. The decoy
      // must never be selected; do not make its atomic responder part of the
      // protected-route qualification claim.
      assign responses[1] = '0;
      always @(posedge clk) if (rst_n)
        assert(!targets[1].aw_valid && !targets[1].ar_valid) else
          $fatal(1, "CHECKPOINT_ROUTE_FAIL wrong-decoded-target");
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
    always @(posedge clk) if (rst_n) begin
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
    .ar_authorized_o(ar_auth), .policy_hold_o(hold_policy)
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
             prot: prot, default: '0};
  endfunction
  function automatic ar_t address_read(input int master, input logic [2:0] prot);
    return '{id: IdW'((master << 4) | 3), addr: Base + 64'h10, size: 3'd2, burst: 2'b01,
             prot: prot, default: '0};
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
                              input bit w_already_accepted = 0);
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
    end
    check(grants == old_grants + int'(expected == 0), "command-once");
    b_ready = 1; tick(); b_ready = 0; tick();
    check(!hold_policy, "write-owner-retired");
  endtask
  task automatic send_ar;
    if (UseMux) selected_master = int'(ar_header.id[5:4]);
    ar_valid = 1; #1;
    for (int n = 0; n < 200 && !resp.ar_ready; n++) tick();
    check(resp.ar_ready, "ar-accept"); tick(); ar_valid = 0;
    for (int n = 0; n < 8 && !hold_policy; n++) tick();
    check(hold_policy, "ar-ownership");
  endtask
  task automatic finish_read(input logic [1:0] expected, input logic [IdW-1:0] id);
    for (int n = 0; n < 200 && !resp.r_valid; n++) tick();
    check(resp.r_valid && resp.r.resp == expected &&
          resp.r.id == (UseMux ? {2'b00, id[3:0]} : id) && resp.r.last,
          "r-response");
    check(resp.r.data == (expected == 0 ? 64'h0000_00F1_0000_00F1 : 0), "r-content");
    repeat (5) begin
      tick();
      check(resp.r_valid && resp.r.resp == expected && hold_policy, "held-r-and-policy");
    end
    r_ready = 1; tick(); r_ready = 0; tick();
    check(!hold_policy, "read-owner-retired");
  endtask
  initial begin
    int before_grants, before_w;
    logic [1:0] expected;
    aw_t header;
    negative = $test$plusargs("oracle_negative");
    aw_header = address_write(0, 1); ar_header = address_read(0, 1);
    repeat (3) tick(); rst_n = 1; tick();
    for (int master = 0; master < (UseMux ? 3 : 4); master++) begin
      for (int prot = 0; prot < 8; prot++) begin
        expected = Enabled && master == 0 && prot == 1 ? 2'b00 : 2'b10;
        before_grants = grants;
        aw_header = address_write(master, 3'(prot));
        send_aw(); finish_write(expected, before_grants, IdW'((master << 4) | 9));
        ar_header = address_read(master, 3'(prot));
        send_ar(); finish_read(expected, IdW'((master << 4) | 3));
      end
    end
    // Unaccepted live headers must neither promote nor revoke the owned packet.
    before_grants = grants; aw_header = address_write(2, 1);
    send_aw(); aw_header = address_write(0, 1);
    finish_write(2, before_grants, 6'h29);
    before_grants = grants; aw_header = address_write(0, 1);
    send_aw(); aw_header = address_write(2, 1);
    finish_write(Enabled ? 0 : 2, before_grants);
    // W can be offered first but is not paired until the bridge accepts AW.
    before_grants = grants; before_w = w_transfers; w_valid = 1; tick();
    check(!resp.w_ready, "w-before-aw-retained");
    aw_header = address_write(0, 1); send_aw();
    finish_write(Enabled ? 0 : 2, before_grants, 6'h09, w_transfers != before_w);
    // Delay downstream AW; policy must be captured at upstream acceptance.
    before_grants = grants; block_aw = 1; aw_header = address_write(0, 1);
    send_aw(); epoch = 8; tick(); epoch = 7; tick(); block_aw = 0;
    finish_write(2, before_grants);
    before_grants = grants; block_aw = 1;
    send_aw(); policy_ready = 0; tick(); policy_ready = 1; tick(); block_aw = 0;
    finish_write(2, before_grants);
    // The independent AR owner has the same sticky loss/ABA rule.
    block_ar = 1; ar_header = address_read(0, 1); send_ar();
    epoch = 9; tick(); epoch = 7; tick(); block_ar = 0;
    finish_read(2, 6'h03);
    block_ar = 1; send_ar(); policy_ready = 0; tick();
    policy_ready = 1; tick(); block_ar = 0; finish_read(2, 6'h03);
    // Locks, cached packets, subword/misaligned requests and ATOPs are not commands.
    for (int malformed = 0; malformed < 7; malformed++) begin
      header = address_write(0, 1);
      case (malformed)
        0: header.lock = 1;
        1: header.cache = 4'hF;
        2: header.size = 1;
        3: header.addr = Base + 1;
        4: header.atop = 1;
        5: header.burst = 2;
        6: strobe = 4'h7;
      endcase
      before_grants = grants; aw_header = header; send_aw(); finish_write(2, before_grants);
      strobe = 4'hF;
    end
    // Provider recovery allows only a new packet, never resurrects an owned one.
    before_grants = grants; aw_header = address_write(0, 1); send_aw();
    finish_write(Enabled ? 0 : 2, before_grants);
    check(!negative, "negative-oracle");
    $display("CHECKPOINT_ROUTE_PASS checks=%0d enabled=%0d mux=%0d spill=%0d xbar=%0d",
             checks, Enabled, UseMux, SpillRequests, UseXbar);
    $finish;
  end
  initial begin #1000000; $fatal(1, "CHECKPOINT_ROUTE_TIMEOUT"); end
endmodule
