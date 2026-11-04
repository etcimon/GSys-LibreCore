// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-009A directed bench for the discovery/lifecycle machine and slot set.
// Synthetic descriptor v1 fixtures are built by make_desc (with a valid
// checksum); expected state/fault values are hand-written per case.
module tb_g6lc_storamic_discovery;
  import g6lc_storamic_discovery_pkg::*;

  localparam int unsigned Deb = 2;
  localparam int unsigned PwrT = 8, DescT = 8, InitT = 16, DescMax = 16;
  localparam logic [3:0] Strap = 4'h5;
  localparam logic [63:0] MaxRam = 64'h10000, MaxFlash = 64'h10000;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  task automatic tick(); @(negedge clk); endtask
  task automatic section(input string s);
    $display("STORAMIC_DISC_SECTION %s", s);
  endtask

  logic presence, pg, init_done, init_err, qreq, drain, fclear;
  logic [3:0] strap;
  logic pen, dreq, ireq, rready, fready, pcap, fev, rev;
  logic [7:0] daddr;
  logic [31:0] ddata;
  logic dvalid, derr;
  state_t st;
  fault_t ft;
  g6lc_storamic_region_pkg::slot_desc_t sdesc;

  g6lc_storamic_discovery #(
    .DebounceCycles(Deb), .PowerTimeout(PwrT), .DescTimeout(DescT),
    .InitTimeout(InitT), .DescMaxWords(DescMax), .MaxRamBytes(MaxRam),
    .MaxFlashBytes(MaxFlash), .SupportedProfile(Strap)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .presence_i(presence), .profile_strap_i(strap), .power_good_i(pg),
    .power_en_o(pen), .desc_req_o(dreq), .desc_addr_o(daddr),
    .desc_valid_i(dvalid), .desc_data_i(ddata), .desc_error_i(derr),
    .init_req_o(ireq), .init_done_i(init_done), .init_error_i(init_err),
    .quiesce_req_i(qreq), .drain_i(drain), .fault_clear_i(fclear),
    .state_o(st), .fault_o(ft), .slot_desc_o(sdesc),
    .ram_ready_o(rready), .flash_ready_o(fready), .persist_ready_o(),
    .persist_cap_o(pcap), .flash_bytes_o(), .erase_bytes_o(),
    .fault_event_o(fev), .ready_event_o(rev)
  );

  // Synthetic descriptor memory + responders.
  logic [31:0] dmem [256];
  int d_latency, d_err_idx;
  bit d_silent, i_silent, i_fail, pg_never;
  int d_lat, i_lat, pg_cnt;
  bit d_served, i_served;
  logic [7:0] d_last;
  task automatic resp_cfg(input int lat, input int err, input bit silent);
    d_latency = lat; d_err_idx = err; d_silent = silent;
  endtask
  always @(posedge clk) begin
    dvalid <= 0; derr <= 0;
    if (!dreq) begin d_lat <= 0; d_served <= 0; d_last <= '1; end
    else begin
      if (daddr != d_last) begin d_served <= 0; d_lat <= 0; d_last <= daddr; end
      if (!d_served && !d_silent) begin
        if (d_lat >= d_latency) begin
          if (daddr == 8'(d_err_idx)) derr <= 1;
          else begin dvalid <= 1; ddata <= dmem[daddr]; end
          d_served <= 1;
        end else d_lat <= d_lat + 1;
      end
    end
    init_done <= 0; init_err <= 0;
    if (!ireq) i_served <= 0;
    else if (!i_served && !i_silent) begin
      if (i_lat >= 2) begin
        if (i_fail) init_err <= 1; else init_done <= 1;
        i_served <= 1;
      end else i_lat <= i_lat + 1;
    end
    if (!pen) pg_cnt <= 0;
    else if (pg_cnt < 4) pg_cnt <= pg_cnt + 1;
    pg <= pen && pg_cnt >= 4 && !pg_never;
  end

  // Build a synthetic v1 descriptor in dmem with a correct checksum.
  task automatic make_desc(input logic [31:0] ident, input logic [31:0] flags,
      input logic [63:0] ram, resv, flash, input logic [31:0] erase,
      input int len = 12, input bit fixsum = 1);
    logic [31:0] s;
    for (int i = 0; i < 256; i++) dmem[i] = '0;
    dmem[0] = DescMagic;
    dmem[1] = (32'(DescVersion) << 16) | 32'(len);
    dmem[2] = ident;
    dmem[3] = flags;
    dmem[4] = ram[31:0]; dmem[5] = ram[63:32];
    dmem[6] = resv[31:0]; dmem[7] = resv[63:32];
    dmem[8] = flash[31:0]; dmem[9] = flash[63:32];
    dmem[10] = erase;
    s = '0;
    for (int i = 0; i < len - 1; i++) s += dmem[i];
    dmem[len - 1] = fixsum ? 0 - s : 32'hDEAD;
  endtask

  task automatic wait_state(input state_t want, input string name);
    int g;
    g = 0;
    do begin @(negedge clk); g++; end while (st != want && g < 500);
    if (st != want) $fatal(1, "STORAMIC_DISC_WAIT %s want=%0d got=%0d", name,
                           want, st);
  endtask

  task automatic clear_to_absent(input string name);
    presence = 0;
    repeat (Deb + 3) tick();
    fclear = 1; tick(); fclear = 0;
    wait_state(Absent, name);
  endtask

  task automatic expect_fault(input fault_t want, input string name);
    wait_state(Fault, name);
    if (ft != want) $fatal(1, "STORAMIC_DISC_FAULT %s want=%0d got=%0d",
                           name, want, ft);
    clear_to_absent(name);
  endtask

  task automatic boot_ready(input string name);
    wait_state(Ready, name);
  endtask

  // Set-level signals (duplicate-identity case).
  logic [2:0] s_pres, s_pg, s_pen, s_dreq, s_dv, s_de, s_ireq, s_idn, s_ie;
  logic [2:0] s_qr, s_dr, s_fc, s_rr, s_fr, s_pc, s_fev, s_rev, s_dup;
  logic [2:0][3:0] s_strap, s_st, s_ft;
  logic [2:0][7:0] s_daddr;
  logic [2:0][31:0] s_ddata;
  g6lc_storamic_region_pkg::slot_map_t smap;
  logic [31:0] sdmem [3][256];
  bit sd_served [3];
  int sd_lat [3];
  logic [7:0] sd_last [3];

  g6lc_storamic_discovery_set #(
    .Slots(3), .DebounceCycles(Deb), .PowerTimeout(PwrT), .DescTimeout(DescT),
    .InitTimeout(InitT), .DescMaxWords(DescMax), .MaxRamBytes(MaxRam),
    .MaxFlashBytes(MaxFlash), .SupportedProfile(Strap)
  ) dut_set (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .presence_i(s_pres), .profile_strap_i(s_strap), .power_good_i(s_pg),
    .power_en_o(s_pen), .desc_req_o(s_dreq), .desc_addr_o(s_daddr),
    .desc_valid_i(s_dv), .desc_data_i(s_ddata), .desc_error_i(s_de),
    .init_req_o(s_ireq), .init_done_i(s_idn), .init_error_i(s_ie),
    .quiesce_req_i(s_qr), .drain_i(s_dr), .fault_clear_i(s_fc),
    .state_o(s_st), .fault_o(s_ft), .slot_map_o(smap), .dup_o(s_dup),
    .ram_ready_o(s_rr), .flash_ready_o(s_fr), .persist_cap_o(s_pc),
    .fault_event_o(s_fev), .ready_event_o(s_rev)
  );

  always @(posedge clk) begin
    for (int s = 0; s < 3; s++) begin
      s_dv[s] <= 0; s_de[s] <= 0;
      if (!s_dreq[s]) begin sd_lat[s] <= 0; sd_served[s] <= 0; sd_last[s] <= '1; end
      else begin
        if (s_daddr[s] != sd_last[s]) begin
          sd_served[s] <= 0; sd_lat[s] <= 0; sd_last[s] <= s_daddr[s];
        end
        if (!sd_served[s]) begin
          if (sd_lat[s] >= 1) begin
            s_dv[s] <= 1; s_ddata[s] <= sdmem[s][s_daddr[s]];
            sd_served[s] <= 1;
          end else sd_lat[s] <= sd_lat[s] + 1;
        end
      end
      s_pg[s] <= s_pen[s];
      s_idn[s] <= s_ireq[s];
      s_ie[s] <= 0;
    end
  end

  task automatic make_sdesc(input int s, input logic [31:0] ident);
    logic [31:0] sum;
    for (int i = 0; i < 256; i++) sdmem[s][i] = '0;
    sdmem[s][0] = DescMagic;
    sdmem[s][1] = (32'(DescVersion) << 16) | 32'd12;
    sdmem[s][2] = ident;
    sdmem[s][3] = 32'h1 | (32'(Strap) << 8);
    sdmem[s][4] = 32'h4000;
    sdmem[s][6] = 32'h100;
    sum = '0;
    for (int i = 0; i < 11; i++) sum += sdmem[s][i];
    sdmem[s][11] = 0 - sum;
  endtask

  bit pen_seen;
  always @(posedge clk) if (pen) pen_seen <= 1;

  logic corrupt;
  int checks = 0;
  task automatic ok(input bit cond, input string name);
    checks++;
    if (!cond) $fatal(1, "STORAMIC_DISC_FAIL %s", name);
  endtask

  initial begin
    corrupt = $test$plusargs("oracle_negative");
    presence = 0; strap = Strap; pg = 0; init_done = 0; init_err = 0;
    qreq = 0; drain = 0; fclear = 0; i_lat = 0; pg_cnt = 0;
    d_latency = 1; d_err_idx = -1; d_silent = 0; i_silent = 0; i_fail = 0;
    pg_never = 0; d_last = '1; d_served = 0; i_served = 0; d_lat = 0;
    pen_seen = 0;
    s_pres = '0; s_strap = '{default: Strap}; s_pg = '0; s_qr = '0; s_dr = '0;
    s_fc = '0; s_idn = '0; s_ie = '0;
    for (int s = 0; s < 3; s++) begin
      sd_served[s] = 0; sd_lat[s] = 0; sd_last[s] = '1;
    end
    repeat (3) tick();
    rst_n = 1;
    tick();

    section("empty");
    repeat (20) tick();
    ok(st == Absent, "empty");

    section("debounce-glitch");
    presence = 1; tick(); presence = 0;
    repeat (Deb + 4) tick();
    ok(st == Absent, "glitch-leaves-absent");

    section("strap-mismatch");
    strap = 4'h9; pen_seen = 0;
    presence = 1;
    wait_state(Fault, "strap");
    ok(ft == FaultProfile, "strap-fault");
    ok(!pen_seen, "strap-no-power");
    clear_to_absent("strap");
    strap = Strap;

    section("ram-only");
    make_desc(32'h111, 32'h1 | (32'(Strap) << 8), 64'h8000, 64'h100, 0, 0);
    presence = 1;
    boot_ready("ram-only");
    ok(sdesc.present && sdesc.identity == 32'h111 &&
       sdesc.ram_bytes == 64'h8000 && sdesc.reserved_bytes == 64'h100 &&
       rready && !fready && !pcap, "ram-only-fields");
    presence = 0;
    wait_state(Fault, "ram-removed");
    ok(ft == FaultRemoved && !pen, "ram-removed");
    clear_to_absent("ram-removed");

    section("flash-only");
    make_desc(32'h222, 32'h2 | (32'(Strap) << 8), 0, 0, 64'h4000, 32'h200);
    presence = 1;
    boot_ready("flash-only");
    ok(fready && !rready, "flash-only-ready");
    presence = 0;
    wait_state(Fault, "flash-removed");
    clear_to_absent("flash-removed");

    section("mixed");
    make_desc(32'h333, 32'h7 | (32'(Strap) << 8), 64'h6000, 64'h40,
              64'h2000, 32'h100);
    presence = 1;
    boot_ready("mixed");
    ok(rready && fready && pcap, "mixed-ready");
    presence = 0;
    wait_state(Fault, "mixed-removed");
    clear_to_absent("mixed-removed");

    section("fault-magic");
    make_desc(32'h444, 32'h1 | (32'(Strap) << 8), 64'h1000, 0, 0, 0);
    dmem[0] = 32'hBAD0; dmem[11] = 0;
    // Recompute checksum so only the magic check fires first anyway.
    presence = 1;
    expect_fault(FaultMagic, "fault-magic");

    section("fault-version");
    make_desc(32'h444, 32'h1 | (32'(Strap) << 8), 64'h1000, 0, 0, 0);
    dmem[1] = (32'd2 << 16) | 32'd12;
    presence = 1;
    expect_fault(FaultVersion, "fault-version");

    section("fault-length");
    make_desc(32'h444, 32'h1 | (32'(Strap) << 8), 64'h1000, 0, 0, 0);
    dmem[1] = (32'(DescVersion) << 16) | 32'd8;
    presence = 1;
    expect_fault(FaultLength, "fault-length");

    section("fault-checksum");
    make_desc(32'h444, 32'h1 | (32'(Strap) << 8), 64'h1000, 0, 0, 0, 12, 0);
    presence = 1;
    expect_fault(FaultChecksum, "fault-checksum");

    section("fault-identity");
    make_desc(32'h0, 32'h1 | (32'(Strap) << 8), 64'h1000, 0, 0, 0);
    presence = 1;
    expect_fault(FaultIdentity, "fault-identity");

    section("fault-flags");
    make_desc(32'h444, 32'h9 | (32'(Strap) << 8), 64'h1000, 0, 0, 0);
    presence = 1;
    expect_fault(FaultFlags, "fault-flags");

    section("fault-capacity");
    make_desc(32'h444, 32'h1 | (32'(Strap) << 8), 64'h20000, 0, 0, 0);
    presence = 1;
    expect_fault(FaultCapacity, "fault-capacity");

    section("fault-geometry");
    make_desc(32'h444, 32'h2 | (32'(Strap) << 8), 0, 0, 64'h4000, 32'h300);
    presence = 1;
    expect_fault(FaultGeometry, "fault-geometry");

    section("fault-reserved");
    make_desc(32'h444, 32'h1 | (32'(Strap) << 8), 64'h1000, 0, 0, 0, 13);
    dmem[11] = 32'hC0DE;
    begin
      logic [31:0] s2;
      s2 = '0;
      for (int i = 0; i < 12; i++) s2 += dmem[i];
      dmem[12] = 0 - s2;
    end
    presence = 1;
    expect_fault(FaultReserved, "fault-reserved");

    section("power-timeout");
    make_desc(32'h444, 32'h1 | (32'(Strap) << 8), 64'h1000, 0, 0, 0);
    pg_never = 1;
    presence = 1;
    expect_fault(FaultPowerTimeout, "power-timeout");
    pg_never = 0;

    section("desc-timeout");
    d_silent = 1;
    presence = 1;
    expect_fault(FaultDescTimeout, "desc-timeout");
    d_silent = 0;

    section("desc-error");
    d_err_idx = 5;
    presence = 1;
    expect_fault(FaultDescRead, "desc-error");
    d_err_idx = -1;

    section("init-error");
    i_fail = 1;
    presence = 1;
    expect_fault(FaultInit, "init-error");
    i_fail = 0;

    section("init-timeout");
    i_silent = 1;
    presence = 1;
    expect_fault(FaultInit, "init-timeout");
    i_silent = 0;

    section("removed-powerwait");
    pg_never = 1;
    presence = 1;
    wait_state(PowerWait, "rw-wait");
    presence = 0;
    wait_state(Fault, "rw-fault");
    ok(ft == FaultRemoved && !pen, "rw-removed");
    clear_to_absent("rw");
    pg_never = 0;

    section("removed-identify");
    d_latency = 40;
    presence = 1;
    wait_state(Identify, "ri-wait");
    presence = 0;
    wait_state(Fault, "ri-fault");
    ok(ft == FaultRemoved, "ri-removed");
    clear_to_absent("ri");
    d_latency = 1;

    section("removed-init");
    i_silent = 1;
    presence = 1;
    wait_state(Initialize, "rin-wait");
    presence = 0;
    wait_state(Fault, "rin-fault");
    ok(ft == FaultRemoved, "rin-removed");
    clear_to_absent("rin");
    i_silent = 0;

    section("removed-ready");
    presence = 1;
    boot_ready("rr-wait");
    presence = 0;
    wait_state(Fault, "rr-fault");
    ok(ft == FaultRemoved && !sdesc.present, "rr-removed");
    clear_to_absent("rr");

    section("removed-quiesce");
    presence = 1;
    boot_ready("rq-wait");
    qreq = 1; tick(); qreq = 0;
    wait_state(Quiesce, "rq-q");
    presence = 0;
    wait_state(Fault, "rq-fault");
    ok(ft == FaultRemoved, "rq-removed");
    clear_to_absent("rq");

    section("clean-quiesce");
    presence = 1;
    boot_ready("cq-wait");
    qreq = 1; tick(); qreq = 0;
    wait_state(Quiesce, "cq-q");
    drain = 1; tick(); drain = 0;
    wait_state(Quiesced, "cq-qd");
    ok(!pen, "cq-power-off");
    presence = 0;
    wait_state(Absent, "cq-absent");

    section("quiesced-removal");
    presence = 1;
    boot_ready("qr-wait");
    qreq = 1; tick(); qreq = 0;
    wait_state(Quiesce, "qr-q");
    drain = 1; tick(); drain = 0;
    wait_state(Quiesced, "qr-qd");
    presence = 0;
    wait_state(Absent, "qr-absent");
    ok(ft != FaultRemoved, "qr-no-fault");

    section("fault-clear-while-present");
    strap = 4'h9;
    presence = 1;
    wait_state(Fault, "fcp-fault");
    fclear = 1; repeat (3) tick(); fclear = 0;
    ok(st == Fault, "fcp-stays");
    strap = Strap;
    presence = 0;
    repeat (Deb + 3) tick();
    fclear = 1; tick(); fclear = 0;
    wait_state(Absent, "fcp-absent");

    section("dup-identity");
    make_sdesc(0, 32'h111);
    make_sdesc(1, 32'h111);
    make_sdesc(2, 32'h222);
    s_pres = 3'b111;
    begin
      int g;
      g = 0;
      do begin @(negedge clk); g++; end while (!(s_st[0] == Ready &&
                 s_st[1] == Ready && s_st[2] == Ready) && g < 1000);
      if (!(s_st[0] == Ready && s_st[1] == Ready && s_st[2] == Ready))
        $fatal(1, "STORAMIC_DISC_WAIT dup-ready s0=%0d s1=%0d s2=%0d",
               s_st[0], s_st[1], s_st[2]);
    end
    repeat (3) tick();
    ok(s_dup[0] && s_dup[1] && !s_dup[2], "dup-flags");
    ok(!smap[0].present && !smap[1].present && smap[2].present &&
       smap[2].identity == 32'h222 && smap[2].ram_bytes == 64'h4000 &&
       smap[2].reserved_bytes == 64'h100, "dup-map");
    ok(!smap[3].present && smap[3].identity == 0, "dup-tail-zero");
    s_pres = '0;
    repeat (Deb + 4) tick();
    s_fc = 3'b111; tick(); s_fc = '0;
    repeat (2) tick();

    section("oracle");
    if (corrupt) $fatal(1, "STORAMIC_DISCOVERY_ORACLE_NEGATIVE");
    $display("STORAMIC_DISCOVERY_PASS checks=%0d", checks);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "STORAMIC_DISCOVERY_TIMEOUT");
  end
endmodule

// Synthesis wrapper: 3-slot discovery set.
module g6lc_storamic_discovery_synth (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input logic [2:0] presence_i,
  input logic [2:0][3:0] profile_strap_i,
  input logic [2:0] power_good_i,
  output logic [2:0] power_en_o,
  output logic [2:0] desc_req_o,
  output logic [2:0][7:0] desc_addr_o,
  input logic [2:0] desc_valid_i,
  input logic [2:0][31:0] desc_data_i,
  input logic [2:0] desc_error_i,
  output logic [2:0] init_req_o,
  input logic [2:0] init_done_i,
  input logic [2:0] init_error_i,
  input logic [2:0] quiesce_req_i,
  input logic [2:0] drain_i,
  input logic [2:0] fault_clear_i,
  output logic [2:0][3:0] state_o,
  output logic [2:0][3:0] fault_o,
  output g6lc_storamic_region_pkg::slot_map_t slot_map_o,
  output logic [2:0] dup_o,
  output logic [2:0] ram_ready_o,
  output logic [2:0] flash_ready_o,
  output logic [2:0] persist_cap_o,
  output logic [2:0] fault_event_o,
  output logic [2:0] ready_event_o
);
  g6lc_storamic_discovery_set #(.Slots(3)) dut (.*);
endmodule
