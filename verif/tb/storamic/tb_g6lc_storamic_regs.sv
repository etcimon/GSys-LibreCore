// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-010A register-block bench: drives g6lc_storamic_regs directly with a
// scriptable AXI-Lite master plus a ProfileModel top-level integration case.
module tb_g6lc_storamic_regs;
  import g6lc_storamic_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick(); @(negedge clk); endtask
  task automatic section(input string s);
    $display("STORAMIC_REGS_SECTION %s", s);
  endtask
  int checks = 0;
  task automatic ok(input bit c, input string name);
    checks++;
    if (!c) $fatal(1, "STORAMIC_REGS_FAIL %s", name);
  endtask

  axil_req_t creq;
  axil_resp_t cresp;
  logic svc, mdl, seqx, stray, inflight, irq;
  logic [2:0] flts;
  logic [1:0] tacc, tref, tret, terr;
  logic [2:0][3:0] s_state, s_fault;
  logic [2:0] s_dup, s_fev, s_rev, s_q, s_fc;
  g6lc_storamic_region_pkg::slot_map_t smap;

  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t RCfg = '{
    Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileModel,
    MaxSticks: 3, RequestedMediaCaps: '0, ModelBase: 'h1000,
    ModelBytes: 'h2000};
  g6lc_storamic_regs #(
    .Cfg(RCfg), .Slots(3), .Regions(4), .DataWidth(64)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .ctrl_req_i(creq), .ctrl_resp_o(cresp),
    .service_ready_i(svc), .model_ready_i(mdl),
    .sequence_exhausted_i(seqx), .faults_i(flts), .stray_i(stray),
    .txn_accept_i(tacc), .txn_refuse_i(tref), .txn_retire_i(tret),
    .txn_error_i(terr), .inflight_i(inflight),
    .slot_state_i(s_state), .slot_fault_i(s_fault), .slot_dup_i(s_dup),
    .slot_map_i(smap), .slot_fault_event_i(s_fev),
    .slot_ready_event_i(s_rev),
    .slot_quiesce_o(s_q), .slot_fault_clear_o(s_fc), .irq_o(irq)
  );

  // Off-profile instance for the reduced-map case.
  axil_req_t oreq;
  axil_resp_t oresp;
  g6lc_storamic_regs #(.Cfg(g6lc_storamic_cfg_pkg::StoramicSkeleton),
                       .Slots(1), .Regions(1), .DataWidth(64)
  ) dut_off (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .ctrl_req_i(oreq), .ctrl_resp_o(oresp),
    .service_ready_i(svc), .model_ready_i(1'b0),
    .sequence_exhausted_i(1'b0), .faults_i('0), .stray_i(1'b0),
    .txn_accept_i('0), .txn_refuse_i('0), .txn_retire_i('0),
    .txn_error_i('0), .inflight_i(1'b0),
    .slot_state_i('0), .slot_fault_i('0), .slot_dup_i('0), .slot_map_i('0),
    .slot_fault_event_i('0), .slot_ready_event_i('0),
    .slot_quiesce_o(), .slot_fault_clear_o(), .irq_o()
  );

  // ST-010B runtime-map instance: mapped profile, BootMapEn=0.
  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t RtCfg = '{
    Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
    MaxSticks: 4, RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0};
  axil_req_t rreq;
  axil_resp_t rresp;
  g6lc_storamic_region_pkg::slot_map_t rt_smap;
  logic [3:0][3:0] rt_state, rt_fault;
  logic [3:0] rt_dup;
  logic rt_map_valid;
  g6lc_storamic_region_pkg::slot_map_t rt_slots_o;
  g6lc_storamic_region_pkg::region_map_t rt_rmap_o;
  g6lc_storamic_regs #(
    .Cfg(RtCfg), .Slots(4), .Regions(8), .DataWidth(64), .BootMapEn(1'b0)
  ) dut_rt (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .ctrl_req_i(rreq), .ctrl_resp_o(rresp),
    .service_ready_i(1'b1), .model_ready_i(1'b0),
    .sequence_exhausted_i(1'b0), .faults_i('0), .stray_i(1'b0),
    .txn_accept_i('0), .txn_refuse_i('0), .txn_retire_i('0),
    .txn_error_i('0), .inflight_i(1'b0),
    .slot_state_i(rt_state), .slot_fault_i(rt_fault),
    .slot_dup_i(rt_dup), .slot_map_i(rt_smap),
    .slot_fault_event_i('0), .slot_ready_event_i('0),
    .slot_quiesce_o(), .slot_fault_clear_o(), .irq_o(),
    .map_valid_o(rt_map_valid), .slot_map_o(rt_slots_o),
    .region_map_o(rt_rmap_o)
  );
  int racc[4];
  always @(posedge clk) begin
    if (rreq.aw_valid && rresp.aw_ready) racc[0]++;
    if (rreq.w_valid && rresp.w_ready) racc[1]++;
    if (rreq.ar_valid && rresp.ar_ready) racc[2]++;
  end

  task automatic rwr(input logic [31:0] a, input logic [31:0] d,
                     output logic [1:0] resp);
    int snap;
    snap = racc[0];
    rreq.aw.addr = a; rreq.aw_valid = 1;
    do @(negedge clk); while (racc[0] == snap);
    rreq.aw_valid = 0;
    snap = racc[1];
    rreq.w.data = d; rreq.w.strb = '1; rreq.w_valid = 1;
    do @(negedge clk); while (racc[1] == snap);
    rreq.w_valid = 0;
    rreq.b_ready = 1;
    while (!rresp.b_valid) @(negedge clk);
    resp = rresp.b.resp;
    tick(); rreq.b_ready = 0;
  endtask

  task automatic rrd(input logic [31:0] a, output logic [31:0] d,
                     output logic [1:0] resp);
    int snap;
    snap = racc[2];
    rreq.ar.addr = a; rreq.ar_valid = 1;
    do @(negedge clk); while (racc[2] == snap);
    rreq.ar_valid = 0;
    rreq.r_ready = 1;
    while (!rresp.r_valid) @(negedge clk);
    d = rresp.r.data; resp = rresp.r.resp;
    tick(); rreq.r_ready = 0;
  endtask

  // Stage one region entry via the REGION[i] window.
  task automatic stage(input int i, input logic [63:0] base, bytes, off,
                       input int slot, input bit rd, wr);
    logic [1:0] r0;
    logic [31:0] a;
    a = 32'h400 + 32'h20 * i;
    rwr(a + 0, base[31:0], r0); rwr(a + 4, base[63:32], r0);
    rwr(a + 8, bytes[31:0], r0); rwr(a + 12, bytes[63:32], r0);
    rwr(a + 16, off[31:0], r0); rwr(a + 20, off[63:32], r0);
    rwr(a + 24, 32'(slot), r0);
    rwr(a + 28, {29'h0, wr, rd, 1'b1}, r0);
  endtask

  task automatic commit(output logic [1:0] resp);
    rwr(32'h020, 32'h1, resp);
  endtask

  task automatic wait_busy();
    int g;
    g = 0;
    do begin @(negedge clk); g++;
    end while (dut_rt.busy_q && g < 400);
    if (g >= 400) $fatal(1, "STORAMIC_REGS_STALL busy");
  endtask

  task automatic mstat(output logic [4:0] st, output bit committed);
    logic [31:0] d0; logic [1:0] r0;
    rrd(32'h020, d0, r0);
    st = d0[12:8]; committed = d0[2];
  endtask

  int acc[12];
  always @(posedge clk) begin
    if (creq.aw_valid && cresp.aw_ready) acc[0]++;
    if (creq.w_valid && cresp.w_ready) acc[1]++;
    if (oreq.aw_valid && oresp.aw_ready) acc[2]++;
    if (oreq.w_valid && oresp.w_ready) acc[3]++;
    if (treq.aw_valid && tresp.aw_ready) acc[4]++;
    if (treq.w_valid && tresp.w_ready) acc[5]++;
    if (treq.ar_valid && tresp.ar_ready) acc[6]++;
    if (tcreq.aw_valid && tcresp.aw_ready) acc[7]++;
    if (tcreq.w_valid && tcresp.w_ready) acc[8]++;
    if (tcreq.ar_valid && tcresp.ar_ready) acc[9]++;
    if (creq.ar_valid && cresp.ar_ready) acc[10]++;
    if (oreq.ar_valid && oresp.ar_ready) acc[11]++;
  end

  task automatic wr(input logic [31:0] a, input logic [31:0] d,
                    input logic [3:0] s, output logic [1:0] resp,
                    input bit w_first = 0);
    int snap, snap2;
  logic [4:0] st5;
  bit cmt;
    if (w_first) begin
      snap = acc[1];
      creq.w.data = d; creq.w.strb = s; creq.w_valid = 1;
      do @(negedge clk); while (acc[1] == snap);
      creq.w_valid = 0;
      snap = acc[0];
      creq.aw.addr = a; creq.aw_valid = 1;
      do @(negedge clk); while (acc[0] == snap);
      creq.aw_valid = 0;
    end else begin
      snap = acc[0];
      creq.aw.addr = a; creq.aw_valid = 1;
      do @(negedge clk); while (acc[0] == snap);
      creq.aw_valid = 0;
      snap = acc[1];
      creq.w.data = d; creq.w.strb = s; creq.w_valid = 1;
      do @(negedge clk); while (acc[1] == snap);
      creq.w_valid = 0;
    end
    creq.b_ready = 1;
    while (!cresp.b_valid) @(negedge clk);
    resp = cresp.b.resp;
    tick();
    creq.b_ready = 0;
  endtask

  task automatic rd(input logic [31:0] a, output logic [31:0] d,
                    output logic [1:0] resp);
    int snap, snap2;
  logic [4:0] st5;
  bit cmt;
    snap = acc[10];
    creq.ar.addr = a; creq.ar_valid = 1;
    do @(negedge clk); while (acc[10] == snap);
    creq.ar_valid = 0;
    creq.r_ready = 1;
    while (!cresp.r_valid) @(negedge clk);
    d = cresp.r.data; resp = cresp.r.resp;
    tick();
    creq.r_ready = 0;
  endtask

  task automatic ord(input logic [31:0] a, output logic [31:0] d,
                     output logic [1:0] resp);
    int snap, snap2;
  logic [4:0] st5;
  bit cmt;
    snap = acc[11];
    oreq.ar.addr = a; oreq.ar_valid = 1;
    do @(negedge clk); while (acc[11] == snap);
    oreq.ar_valid = 0;
    oreq.r_ready = 1;
    while (!oresp.r_valid) @(negedge clk);
    d = oresp.r.data; resp = oresp.r.resp;
    tick();
    oreq.r_ready = 0;
  endtask

  task automatic owr(input logic [31:0] a, input logic [31:0] d,
                     output logic [1:0] resp);
    int snap, snap2;
  logic [4:0] st5;
  bit cmt;
    snap = acc[2];
    oreq.aw.addr = a; oreq.aw_valid = 1;
    do @(negedge clk); while (acc[2] == snap);
    oreq.aw_valid = 0;
    snap = acc[3];
    oreq.w.data = d; oreq.w.strb = '1; oreq.w_valid = 1;
    do @(negedge clk); while (acc[3] == snap);
    oreq.w_valid = 0;
    oreq.b_ready = 1;
    while (!oresp.b_valid) @(negedge clk);
    resp = oresp.b.resp;
    tick();
    oreq.b_ready = 0;
  endtask

  logic [31:0] d;
  logic [1:0] rsp;
  int snap, snap2;
  logic [4:0] st5;
  bit cmt;
  logic seen_q0, seen_fc0, flags_clr;
  always @(posedge clk) begin
    if (flags_clr) begin seen_q0 <= 0; seen_fc0 <= 0; end
    else begin
      if (s_q[0]) seen_q0 <= 1;
      if (s_fc[0]) seen_fc0 <= 1;
    end
  end
  logic corrupt;

  // Top-level integration: ProfileModel top + trivial memory responder.
  axi_req_t treq;
  axi_resp_t tresp;
  axil_req_t tcreq;
  axil_resp_t tcresp;
  logic tm_ready, tm_req, tm_gnt, tm_we, tm_rvalid, tm_error;
  logic [63:0] tm_addr, tm_wdata;
  logic [7:0] tm_be, tm_slot;
  g6lc_storamic_pkg::txn_id_t tm_tag_o, tm_tag_i;
  logic tirq;
  g6lc_storamic_top #(.Cfg(g6lc_storamic_cfg_pkg::StoramicModel)) tdut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .req_i(treq), .resp_o(tresp),
    .ctrl_req_i(tcreq), .ctrl_resp_o(tcresp),
    .init_done_o(), .service_ready_o(), .media_ready_o(), .pad_o(),
    .source_i('0), .reset_generation_i('0), .model_ready_o(),
    .sequence_exhausted_o(), .faults_o(), .events_o(), .irq_o(tirq),
    .mem_ready_i(tm_ready), .mem_req_o(tm_req), .mem_gnt_i(tm_gnt),
    .mem_we_o(tm_we), .mem_addr_o(tm_addr), .mem_wdata_o(tm_wdata),
    .mem_be_o(tm_be), .mem_tag_o(tm_tag_o), .mem_slot_o(tm_slot),
    .mem_rvalid_i(tm_rvalid), .mem_rdata_i('0), .mem_error_i(tm_error),
    .mem_tag_i(tm_tag_i), .stray_i(1'b0)
  );
  always @(posedge clk) begin
    tm_rvalid <= 0;
    if (tm_req && tm_gnt) begin
      tm_rvalid <= 1;
      tm_tag_i <= tm_tag_o;
      tm_error <= 0;
    end
  end
  assign tm_ready = 1;
  assign tm_gnt = tm_req;

  task automatic twr(input logic [63:0] a, input logic [63:0] dw);
    int snap, snap2;
  logic [4:0] st5;
  bit cmt;
    snap = acc[4];
    treq.aw.addr = a; treq.aw.len = 0; treq.aw.size = 3; treq.aw.burst = 1;
    treq.aw_valid = 1;
    do @(negedge clk); while (acc[4] == snap);
    treq.aw_valid = 0;
    snap = acc[5];
    treq.w.data = dw; treq.w.strb = '1; treq.w.last = 1; treq.w_valid = 1;
    do @(negedge clk); while (acc[5] == snap);
    treq.w_valid = 0;
    treq.b_ready = 1;
    while (!tresp.b_valid) @(negedge clk);
    tick();
    treq.b_ready = 0;
  endtask

  task automatic trd(input logic [63:0] a);
    int snap, snap2;
  logic [4:0] st5;
  bit cmt;
    snap = acc[6];
    treq.ar.addr = a; treq.ar.len = 0; treq.ar.size = 3; treq.ar.burst = 1;
    treq.ar_valid = 1;
    do @(negedge clk); while (acc[6] == snap);
    treq.ar_valid = 0;
    treq.r_ready = 1;
    while (!(tresp.r_valid && tresp.r.last)) @(negedge clk);
    tick();
    treq.r_ready = 0;
  endtask

  task automatic tcwr(input logic [31:0] a, input logic [31:0] dw);
    int snap, snap2;
  logic [4:0] st5;
  bit cmt;
    snap = acc[7];
    tcreq.aw.addr = a; tcreq.aw_valid = 1;
    do @(negedge clk); while (acc[7] == snap);
    tcreq.aw_valid = 0;
    snap = acc[8];
    tcreq.w.data = dw; tcreq.w.strb = '1; tcreq.w_valid = 1;
    do @(negedge clk); while (acc[8] == snap);
    tcreq.w_valid = 0;
    tcreq.b_ready = 1;
    while (!tcresp.b_valid) @(negedge clk);
    tick();
    tcreq.b_ready = 0;
  endtask

  task automatic tcrd(input logic [31:0] a, output logic [31:0] dw);
    int snap, snap2;
  logic [4:0] st5;
  bit cmt;
    snap = acc[9];
    tcreq.ar.addr = a; tcreq.ar_valid = 1;
    do @(negedge clk); while (acc[9] == snap);
    tcreq.ar_valid = 0;
    tcreq.r_ready = 1;
    while (!tcresp.r_valid) @(negedge clk);
    dw = tcresp.r.data;
    tick();
    tcreq.r_ready = 0;
  endtask

  initial begin
    corrupt = $test$plusargs("oracle_negative");
    creq = '0; oreq = '0; treq = '0; tcreq = '0; rreq = '0;
    rt_state = '{default: 4'd7}; rt_fault = '0; rt_dup = '0;
    rt_smap = '{default: '0};
    for (int i = 0; i < 4; i++)
      rt_smap[i] = '{present: 1, identity: 32'h100 + i,
                     ram_bytes: 64'h8000, reserved_bytes: 64'h100};
    svc = 1; mdl = 1; seqx = 0; stray = 0; inflight = 1;
    flts = '0; tacc = '0; tref = '0; tret = '0; terr = '0;
    s_state = '{default: 4'd7}; s_fault = '{default: 4'd0};
    s_dup = 3'b100; s_fev = '0; s_rev = '0;
    smap = '{default: '0};
    smap[0] = '{present: 1, identity: 32'h111, ram_bytes: 64'h8000,
                reserved_bytes: 64'h100};
    smap[1] = '{present: 1, identity: 32'h222, ram_bytes: 64'h4000,
                reserved_bytes: 64'h40};
    repeat (3) tick();
    rst_n = 1;
    tick();

    section("decode");
    rd(32'h000, d, rsp); ok(rsp == 0 && d == 32'h5354_524D, "id");
    rd(32'h004, d, rsp); ok(rsp == 0 && d[15:0] == 4, "version");
    rd(32'h008, d, rsp);
    ok(rsp == 0 && d[1:0] == 2'b10 && d[7:4] == 3 && d[12:8] == 4 &&
       d[23:16] == 3, "config");
    rd(32'h00C, d, rsp); ok(rsp == 0 && d[1:0] == 2'b11 && d[4] == 0, "status");
    rd(32'h010, d, rsp); ok(rsp == 0 && d == 0, "caps");
    rd(32'h014, d, rsp); ok(rsp == 0 && d == 0, "faults-reset");
    rd(32'h018, d, rsp); ok(rsp == 0 && d == 0, "irqen-reset");
    rd(32'h01C, d, rsp); ok(rsp == 0 && d == 0, "irqpend-reset");
    rd(32'h020, d, rsp); ok(rsp == 0 && d == 0, "mapctrl-model");
    rd(32'h024, d, rsp); ok(rsp == 0 && d == 0, "drain-reset");
    rd(32'h028, d, rsp); ok(rsp == 0 && d == 0, "draindone-reset");
    rd(32'h02C, d, rsp); ok(rsp == 0 && d == 0, "cntaccept-reset");
    rd(32'h030, d, rsp); ok(rsp == 0 && d == 0, "cntrefuse-reset");
    rd(32'h034, d, rsp); ok(rsp == 0 && d == 0, "cntcomplete-reset");
    rd(32'h038, d, rsp); ok(rsp == 0 && d == 0, "cnterror-reset");

    section("unmapped-misaligned");
    rd(32'h03C, d, rsp); ok(rsp == 2'b10 && d == 0, "unmapped-hole");
    rd(32'h400, d, rsp); ok(rsp == 2'b10, "region-unmapped");
    rd(32'h100 + 32'h60, d, rsp); ok(rsp == 2'b10, "slot-over-maxsticks");
    rd(32'h002, d, rsp); ok(rsp == 2'b10, "misaligned-read");
    wr(32'h03C, 32'hFF, '1, rsp); ok(rsp == 2'b10, "unmapped-write");
    wr(32'h006, 32'hFF, '1, rsp); ok(rsp == 2'b10, "misaligned-write");
    wr(32'h020, 32'h1, '1, rsp); ok(rsp == 2'b10, "mapctrl-commit-sflverr");
    wr(32'h000, 32'hFF, '1, rsp); ok(rsp == 2'b10, "ro-write");

    section("strobes");
    wr(32'h018, 32'h0000_00F0, 4'b1111, rsp);
    ok(rsp == 0, "irqen-write");
    rd(32'h018, d, rsp); ok(d == 0, "irqen-masked-high");
    wr(32'h018, 32'h0000_0009, 4'b0001, rsp);
    rd(32'h018, d, rsp); ok(d == 4'h9, "irqen-byte0");
    wr(32'h018, 32'hF0, 4'b0010, rsp);
    rd(32'h018, d, rsp); ok(d == 4'h9, "irqen-byte1-noop");
    wr(32'h024, 32'hCAFE_0000, 4'b1100, rsp);
    rd(32'h024, d, rsp); ok(d == 32'hCAFE_0000, "token-hi");
    wr(32'h024, 32'h1234, 4'b0001, rsp);
    rd(32'h024, d, rsp); ok(d == 32'hCAFE_0034, "token-lo");

    section("faults-w1c");
    flts = 3'b011; stray = 1;
    tick();
    stray = 0; flts = '0;
    tick();
    rd(32'h014, d, rsp); ok(d[3:0] == 4'b1011, "faults-set");
    rd(32'h01C, d, rsp); ok(d[0] == 1, "irqpend-fault");
    wr(32'h014, 32'h3, 4'b0001, rsp); // clear [1:0] via strobed byte
    rd(32'h014, d, rsp); ok(d[3:0] == 4'b1000, "faults-w1c");
    wr(32'h014, 32'hF0, 4'b0000, rsp); // no strobe: nothing clears
    rd(32'h014, d, rsp); ok(d[3:0] == 4'b1000, "faults-nostrobe");

    section("irq");
    wr(32'h018, 32'h9, '1, rsp); // enable bits 0,3
    repeat (2) tick();
    ok(irq, "irq-level");
    // Simultaneous event + W1C on bit0: preload AW+W, then land the fault
    // on the execute posedge so the event truly collides with the clear.
    begin
      snap = acc[0]; snap2 = acc[1];
      creq.aw.addr = 32'h01C; creq.aw_valid = 1;
      creq.w.data = 32'h1; creq.w.strb = '1; creq.w_valid = 1;
      do @(negedge clk); while (!(acc[0] > snap && acc[1] > snap2));
      creq.aw_valid = 0; creq.w_valid = 0;
      flts = 3'b100; // fault_set sampled on the same edge wr_go executes
      creq.b_ready = 1;
      while (!cresp.b_valid) @(negedge clk);
      tick(); creq.b_ready = 0;
      flts = '0;
      rd(32'h01C, d, rsp); ok(d[0] == 1, "event-wins-w1c");
    end
    // Clear bit0 for real; irq stays (no enabled pending left? bit3 pending=0).
    wr(32'h014, 32'h4, '1, rsp); // clear FAULTS[2]
    wr(32'h01C, 32'h9, '1, rsp); // W1C pending 0+3
    rd(32'h01C, d, rsp); ok(d == 0, "irqpend-cleared");
    tick();
    ok(!irq, "irq-deassert-timing");

    section("counters");
    tacc = 2; tref = 1; tret = 1; terr = 0;
    tick();
    tacc = 1; tref = 0; tret = 2; terr = 1;
    tick();
    tacc = '0; tret = '0; terr = '0;
    tick();
    rd(32'h02C, d, rsp); ok(d == 3, "cnt-accept");
    rd(32'h030, d, rsp); ok(d == 1, "cnt-refuse");
    rd(32'h034, d, rsp); ok(d == 3, "cnt-complete");
    rd(32'h038, d, rsp); ok(d == 1, "cnt-error");

    section("drain-token");
    // inflight has been held since reset: the CAFE_1234 token written in the
    // strobes section is still pending (its snapshot predates the counters).
    rd(32'h00C, d, rsp); ok(d[4] == 1, "drain-pending");
    inflight = 0; // let it complete: retire_total 3 >= snapshot 0
    repeat (3) tick();
    rd(32'h028, d, rsp); ok(d == 32'hCAFE_0034, "drain-done-cafe");
    rd(32'h01C, d, rsp); ok(d[3] == 1, "drain-irq-pend");
    wr(32'h01C, 32'h8, '1, rsp);
    // A5 token while pending is kept by inflight: DRAIN_DONE stays CAFE.
    inflight = 1;
    wr(32'h024, 32'hA5, '1, rsp);
    rd(32'h00C, d, rsp); ok(d[4] == 1, "drain-pending-a5");
    rd(32'h028, d, rsp); ok(d == 32'hCAFE_0034, "draindone-notyet");
    inflight = 0; // retire_total 3 >= snapshot 3 -> done
    repeat (3) tick();
    rd(32'h028, d, rsp); ok(d == 32'hA5, "drain-done");
    // Replacement while pending: second token wins.
    inflight = 1;
    wr(32'h024, 32'h11, '1, rsp);
    wr(32'h024, 32'h22, '1, rsp);
    rd(32'h024, d, rsp); ok(d == 32'h22, "token-replace");
    inflight = 0;
    repeat (3) tick();
    rd(32'h028, d, rsp); ok(d == 32'h22, "drain-done-replaced");

    section("slot-view");
    rd(32'h100, d, rsp);
    ok(rsp == 0 && d[3:0] == 7 && d[11:8] == 0 && d[16] == 0, "slot0-state");
    rd(32'h104, d, rsp); ok(d == 32'h111, "slot0-ident");
    rd(32'h108, d, rsp); ok(d == 32'h8000, "slot0-ramlo");
    rd(32'h10C, d, rsp); ok(d == 0, "slot0-ramhi");
    rd(32'h110, d, rsp); ok(d == 32'h100, "slot0-rsvlo");
    rd(32'h140, d, rsp); ok(d[16] == 1, "slot2-dup");
    s_state[1] = 4'd5; s_fault[1] = 4'd8;
    rd(32'h120, d, rsp); ok(d[3:0] == 5 && d[11:8] == 8, "slot1-view");
    flags_clr = 1; tick(); flags_clr = 0;
    wr(32'h118, 32'h3, '1, rsp); // slot0 CTRL quiesce+fclear
    ok(rsp == 0, "ctrl-write");
    ok(seen_q0 && seen_fc0, "ctrl-pulses");
    tick();
    ok(!s_q[0] && !s_fc[0], "ctrl-pulse-off");

    section("off-profile");
    ord(32'h000, d, rsp); ok(rsp == 0 && d == 32'h5354_524D, "off-id");
    ord(32'h004, d, rsp); ok(rsp == 0 && d[15:0] == 4, "off-ver");
    ord(32'h008, d, rsp); ok(rsp == 0 && d[1:0] == 2'b01, "off-config");
    ord(32'h00C, d, rsp); ok(rsp == 0 && d[0] == 1, "off-status");
    ord(32'h010, d, rsp); ok(rsp == 0 && d == 0, "off-caps");
    ord(32'h014, d, rsp); ok(rsp == 2'b10, "off-faults-unmapped");
    ord(32'h100, d, rsp); ok(rsp == 2'b10, "off-slot-unmapped");
    owr(32'h018, 32'hF, rsp); ok(rsp == 2'b10, "off-irqen-sflverr");

    section("order-backpressure");
    wr(32'h018, 32'h5, '1, rsp, .w_first(1)); // W before AW
    rd(32'h018, d, rsp); ok(d == 5, "w-before-aw");
    // R backpressure: hold r_ready low, response must stay stable.
    snap = acc[10];
    creq.ar.addr = 32'h024; creq.ar_valid = 1;
    do @(negedge clk); while (acc[10] == snap);
    creq.ar_valid = 0;
    repeat (3) begin
      tick();
      ok(cresp.r_valid && cresp.r.data == 32'h22, "r-stable-backpressure");
    end
    creq.r_ready = 1; tick(); creq.r_ready = 0;
    // B backpressure.
    snap = acc[0];
    creq.aw.addr = 32'h018; creq.aw_valid = 1;
    do @(negedge clk); while (acc[0] == snap);
    creq.aw_valid = 0;
    snap = acc[1];
    creq.w.data = 32'h7; creq.w.strb = '1; creq.w_valid = 1;
    do @(negedge clk); while (acc[1] == snap);
    creq.w_valid = 0;
    repeat (3) begin
      tick();
      ok(cresp.b_valid && cresp.b.resp == 0, "b-stable-backpressure");
    end
    creq.b_ready = 1; tick(); creq.b_ready = 0;

    section("reset-mid-txn");
    snap = acc[0];
    creq.aw.addr = 32'h018; creq.aw_valid = 1;
    do @(negedge clk); while (acc[0] == snap);
    creq.aw_valid = 0;
    rst_n = 0;
    repeat (2) tick();
    ok(!cresp.b_valid && !cresp.r_valid, "reset-clears");
    rst_n = 1;
    repeat (3) tick();
    rd(32'h018, d, rsp); ok(d == 0, "reset-irqen");

    section("top-integration");
    twr(64'h1000, 64'hDEAD_BEEF);
    trd(64'h1000);
    tcrd(32'h02C, d); ok(d == 2, "top-cnt-accept");
    tcrd(32'h034, d); ok(d == 2, "top-cnt-complete");
    tcwr(32'h024, 32'h5A);
    begin
      int g; g = 0;
      do begin @(negedge clk); g++; end while (g < 60);
    end
    tcrd(32'h028, d); ok(d == 32'h5A, "top-drain-done");
    tcrd(32'h01C, d); ok(d[3] == 1, "top-drain-irq");

    section("runtime-map");
    // (a) legal staged map commits.
    stage(0, 64'h0000, 64'h800, 64'h000, 0, 1, 1);
    stage(1, 64'h0800, 64'h400, 64'h200, 1, 1, 1);
    stage(2, 64'h0C00, 64'h400, 64'h000, 2, 1, 0);
    commit(rsp); ok(rsp == 0, "rt-commit-ok-accept");
    wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapOk && cmt,
                        "rt-commit-ok");
    ok(rt_map_valid, "rt-map-valid");
    ok(rt_rmap_o[0].slot_identity == 32'h100 &&
       rt_rmap_o[1].slot_identity == 32'h101, "rt-ident-captured");
    ok(rt_rmap_o[0].base == 0 && rt_rmap_o[0].bytes == 64'h800 &&
       rt_rmap_o[0].slot == 0 && rt_rmap_o[0].write &&
       !rt_rmap_o[2].write && rt_rmap_o[2].read, "rt-committed-fields");
    rrd(32'h01C, d, rsp); ok(d[2] == 1, "rt-commit-irq");
    // (e) commit while committed and a staged write -> SLVERR.
    commit(rsp); ok(rsp == 2'b10, "rt-commit-while-committed");
    rwr(32'h400, 32'h0, rsp); ok(rsp == 2'b10, "rt-write-committed");
    // (b) failure statuses; a committed map blocks retry so each case
    // takes a fresh reset and re-stages.
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapRegionCount &&
                        !cmt, "rt-regioncount");
    rrd(32'h014, d, rsp); ok(d[5] == 1, "rt-fault5");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'h0, 64'h0, 64'h0, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapRegionEmpty,
                        "rt-regionempty");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'h4, 64'h40, 64'h0, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapRegionAlign,
                        "rt-regionalign");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'hFFFF_FFFF_FFFF_FF80, 64'h100, 64'h0, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapRegionOverflow,
                        "rt-regionoverflow");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'h100, 64'h100, 64'h0, 0, 1, 1);
    stage(1, 64'h80, 64'h80, 64'h0, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapRegionOrder,
                        "rt-regionorder");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'h0, 64'h40, 64'h0, 4, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapSlotIndex,
                        "rt-slotindex");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    rt_smap[3].present = 0;
    stage(0, 64'h0, 64'h40, 64'h0, 3, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapSlotAbsent,
                        "rt-slotabsent");
    rt_smap[3].present = 1;
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'h0, 64'h40, 64'h0, 0, 0, 0);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapPermission,
                        "rt-permission");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'h0, 64'h40, 64'h7F00, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapBackingExtent,
                        "rt-backingextent");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'h0, 64'h100, 64'h0, 0, 1, 1);
    stage(1, 64'h100, 64'h100, 64'h80, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapBackingAlias,
                        "rt-backingalias");
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    rt_smap[0].reserved_bytes = 64'h9000;
    stage(0, 64'h0, 64'h40, 64'h0, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapReservation,
                        "rt-reservation");
    rt_smap[0].reserved_bytes = 64'h100;
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    rt_smap[1].identity = 0;
    stage(0, 64'h0, 64'h40, 64'h0, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapIdentityZero,
                        "rt-idzero");
    rt_smap[1].identity = 32'h101;
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    rt_smap[1].identity = 32'h100;
    stage(0, 64'h0, 64'h40, 64'h0, 0, 1, 1);
    commit(rsp); wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapIdentityDuplicate,
                        "rt-iddup");
    rt_smap[1].identity = 32'h101;
    // (d) write during busy -> SLVERR, then retry after failure.
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    stage(0, 64'h0, 64'h40, 64'h0, 0, 1, 1);
    begin
      snap = racc[0];
      rreq.aw.addr = 32'h020; rreq.aw_valid = 1;
      do @(negedge clk); while (racc[0] == snap);
      rreq.aw_valid = 0;
      snap = racc[1];
      rreq.w.data = 1; rreq.w.strb = '1; rreq.w_valid = 1;
      do @(negedge clk); while (racc[1] == snap);
      rreq.w_valid = 0;
      rreq.b_ready = 1;
      while (!rresp.b_valid) @(negedge clk);
      tick(); rreq.b_ready = 0;
      rwr(32'h400, 32'h55, rsp);
      ok(rsp == 2'b10, "rt-write-busy");
    end
    wait_busy();
    mstat(st5, cmt); ok(st5 == g6lc_storamic_region_pkg::MapOk && cmt,
                        "rt-retry-ok");
    // (c) randomized compare vs map_check (200 iters, biased legal).
    rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
    begin
      int mism, nlead;
      g6lc_storamic_region_pkg::region_map_t omap;
      g6lc_storamic_region_pkg::map_status_t exp_st;
      mism = 0;
      for (int iters = 0; iters < 200; iters++) begin
        rst_n = 0; repeat (2) tick(); rst_n = 1; repeat (3) tick();
        for (int k = 0; k < 4; k++) begin
          rt_smap[k].present = ($urandom_range(0, 99) < 90);
          rt_smap[k].identity = 32'h200 + 32'(k);
          rt_smap[k].ram_bytes = 64'h8000;
          rt_smap[k].reserved_bytes =
              ($urandom_range(0, 99) < 10) ? 64'h9000 : 64'h100;
        end
        nlead = $urandom_range(0, 4);
        for (int i = 0; i < 8; i++) begin
          if (i < nlead) begin
            int sl;
            sl = $urandom_range(0, 5);
            omap[i].valid = 1;
            omap[i].base = 64'($urandom_range(0, 7)) * 64'h800;
            omap[i].bytes = ($urandom_range(0, 99) < 10) ? 64'h0 :
                64'($urandom_range(0, 3) + 1) * 64'h40;
            omap[i].slot = 8'(sl);
            omap[i].offset = 64'($urandom_range(0, 7)) * 64'h100;
            omap[i].read = $urandom_range(0, 99) < 70;
            omap[i].write = ($urandom_range(0, 99) < 70) || !omap[i].read;
            omap[i].slot_identity =
                (sl < 4) ? rt_smap[sl].identity : 32'h0;
            stage(i, omap[i].base, omap[i].bytes, omap[i].offset,
                  int'(omap[i].slot), omap[i].read, omap[i].write);
          end else omap[i] = '0;
        end
        commit(rsp); wait_busy();
        mstat(st5, cmt);
        nlead = 0;
        for (int i = 0; i < 8; i++)
          if (omap[i].valid) nlead = i + 1;
          else break;
        exp_st = g6lc_storamic_region_pkg::map_check(
            rt_smap, 4, omap, nlead, 8);
        if (st5 != 5'(exp_st)) begin
          mism++;
          $display("RTMISMATCH iter=%0d hw=%0d exp=%0d", iters, st5, exp_st);
        end
      end
      ok(mism == 0, "rt-random-compare");
      $display("STORAMIC_REGS_RT_COMPARE iters=200 mism=%0d", mism);
    end

    section("oracle");
    if (corrupt) $fatal(1, "STORAMIC_REGS_ORACLE_NEGATIVE");
    $display("STORAMIC_REGS_PASS checks=%0d", checks);
    $finish;
  end

  initial begin
    #500000;
    $fatal(1, "STORAMIC_REGS_TIMEOUT");
  end
endmodule

// Synthesis wrapper: 3-slot register block in the model profile.
module g6lc_storamic_regs_synth (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  input logic [2:0] faults_i,
  input logic [1:0] txn_accept_i,
  input logic [2:0][3:0] slot_state_i,
  input g6lc_storamic_region_pkg::slot_map_t slot_map_i,
  output logic [2:0] slot_quiesce_o,
  output logic [2:0] slot_fault_clear_o,
  output logic irq_o
);
  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t RCfg = '{
    Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileModel,
    MaxSticks: 3, RequestedMediaCaps: '0, ModelBase: 'h1000,
    ModelBytes: 'h2000};
  g6lc_storamic_regs #(
    .Cfg(RCfg), .Slots(3), .Regions(4), .DataWidth(64)
  ) dut (
    .clk_i, .rst_ni, .testmode_i, .ctrl_req_i, .ctrl_resp_o,
    .service_ready_i(1'b1), .model_ready_i(1'b1),
    .sequence_exhausted_i(1'b0), .faults_i, .stray_i(1'b0),
    .txn_accept_i, .txn_refuse_i('0), .txn_retire_i('0), .txn_error_i('0),
    .inflight_i(1'b0),
    .slot_state_i, .slot_fault_i('0), .slot_dup_i('0), .slot_map_i,
    .slot_fault_event_i('0), .slot_ready_event_i('0),
    .slot_quiesce_o, .slot_fault_clear_o, .irq_o,
    .map_valid_o(), .slot_map_o(), .region_map_o()
  );
endmodule
