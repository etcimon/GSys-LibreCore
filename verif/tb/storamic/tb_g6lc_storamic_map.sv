// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-008B leaf: MapEn=1 frontend + slot mux + per-slot SRAM fixtures with an
// INDEPENDENT per-slot byte oracle maintained by literal arithmetic on the
// declared map (never the package functions or DUT translation).
module tb_g6lc_storamic_map #(
  parameter int unsigned Slots = 2,
  parameter int unsigned DataWidth = 64,
  parameter bit BootMapEn = 1'b1
);
  import g6lc_storamic_region_pkg::*;
  localparam int unsigned Bytes = DataWidth / 8;
  localparam int unsigned IdWidth = 8;
  typedef logic [IdWidth-1:0] id_t;
  typedef struct packed {
    id_t id; logic [63:0] addr; logic [7:0] len; logic [2:0] size;
    logic [1:0] burst; logic lock; logic [3:0] cache, prot, qos, region;
    logic [5:0] atop; logic user;
  } ax_t;
  typedef struct packed {
    logic [DataWidth-1:0] data; logic [Bytes-1:0] strb; logic last, user;
  } w_t;
  typedef struct packed { id_t id; logic [1:0] resp; logic user; } b_t;
  typedef struct packed {
    id_t id; logic [DataWidth-1:0] data; logic [1:0] resp; logic last, user;
  } r_t;
  typedef struct packed {
    ax_t aw; logic aw_valid; w_t w; logic w_valid, b_ready;
    ax_t ar; logic ar_valid, r_ready;
  } req_t;
  typedef struct packed {
    logic aw_ready, w_ready; b_t b; logic b_valid, ar_ready; r_t r; logic r_valid;
  } resp_t;

  localparam int unsigned MaxSlots = Slots;
  localparam int unsigned Cap0 = 'h4000, Cap1 = 'h8000, Cap2 = 'h6000;
  localparam int unsigned MaxCap = 'h8000;
  localparam int unsigned NRegions = Slots == 1 ? 4 : Slots == 2 ? 6 : Slots + 4;
  // Slot and offset for the second (adjacent) region: slot 1 when present,
  // else extra backing on slot 0. offA likewise keeps Slots=1 legal.
  localparam int unsigned SlotA = Slots >= 2 ? 1 : 0;
  localparam int unsigned OffA = Slots >= 2 ? 'h200 : 'h1000;
  localparam int unsigned SlotB = Slots >= 3 ? 2 : 1;
  localparam logic [63:0] OffB = Slots >= 3 ? 64'h0 : 64'h3000;
  localparam logic [63:0] OffC = Slots >= 3 ? 64'h400 : 64'h4000;

  function automatic slot_map_t mk_slots();
    slot_map_t m;
    m = '{default: '0};
    for (int i = 0; i < MaxSlots; i++)
      m[i] = '{present: i < Slots, identity: 32'h7000 + 32'(i),
               ram_bytes: 64'(i == 0 ? Cap0 : i == 1 ? Cap1 :
                              i == 2 ? Cap2 : 'h8000),
               reserved_bytes: 64'(i) * 64'h100};
    return m;
  endfunction

  function automatic region_t rg(input logic [63:0] base, bytes, offset,
      input int slot, input logic [31:0] id, input logic rd, wr);
    return '{valid: 1'b1, base: base, bytes: bytes, slot: 8'(slot),
             slot_identity: id, offset: offset, read: rd, write: wr};
  endfunction

  localparam slot_map_t SMap = mk_slots();
  function automatic region_map_t mk_regions();
    region_map_t r;
    r = '{default: '0};
    r[0] = rg(64'h0,    64'h800, 64'h0,   0,     32'h7000, 1, 1);
    r[1] = rg(64'h800,  64'h400, 64'(OffA), SlotA, 32'h7000 + SlotA, 1, 1);
    r[2] = rg(64'hC00,  64'h400, 64'h800, 0,     32'h7000, 1, 0);
    r[3] = rg(64'h1800, 64'h400, 64'h2000, SlotA, 32'h7000 + SlotA, 0, 1);
`ifdef STORAMIC_MAP_ILLEGAL
    // Deliberately aliasing backing: r1 on slot0 at offset 0x200 overlaps
    // r0's backing [0, 0x800) -> MapBackingAlias -> STORAMIC_MODEL_CONFIG_ILLEGAL.
    r[1] = rg(64'h800, 64'h400, 64'h200, 0, 32'h7000, 1, 1);
`endif
    if (Slots >= 2) begin
      int idx;
      idx = 4;
      r[idx] = rg(64'h3000, 64'h400, OffB, SlotB, 32'h7000 + SlotB, 1, 1);
      idx++;
      if (Slots >= 3) begin
        r[idx] = rg(64'h3800, 64'h400, 64'h800, 2, 32'h7002, 1, 0);
        idx++;
      end
      // One RW region per extra slot k = 3..Slots-1, before top-of-space.
      for (int k = 3; k < Slots; k++) begin
        r[idx] = rg(64'h4000 + 64'h400 * 64'(k - 3), 64'h400, 64'h0, k,
                    32'h7000 + 32'(k), 1, 1);
        idx++;
      end
      // Sorted order: the top-of-space region is always the highest index.
      r[idx] = rg(64'hFFFF_FFFF_FFFF_FE00, 64'h200, OffC,
                  SlotB, 32'h7000 + SlotB, 1, 1);
    end
    return r;
  endfunction
  localparam region_map_t RMap = mk_regions();

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;
  req_t req;
  resp_t resp;
  logic [7:0] mem_slot;
  logic mem_ready, mem_req, mem_gnt, mem_we, mem_rvalid, mem_error;
  logic [63:0] mem_addr;
  logic [DataWidth-1:0] mem_wdata, mem_rdata;
  logic [Bytes-1:0] mem_be;
  g6lc_storamic_pkg::txn_id_t mem_tag_o, mem_tag_i;
  logic stray;
  logic [Slots-1:0] s_ready, s_req, s_gnt, s_rvalid, s_error;
  logic s_we;
  logic [63:0] s_addr;
  logic [DataWidth-1:0] s_wdata;
  logic [Bytes-1:0] s_be;
  g6lc_storamic_pkg::txn_id_t s_tag_o;
  g6lc_storamic_pkg::txn_id_t [Slots-1:0] s_tag_i, model_tag;
  logic [Slots-1:0][DataWidth-1:0] s_rdata;
  logic [DataWidth-1:0] model_data [Slots];
  logic [Slots-1:0] available, inject_stray, model_rvalid;
  logic corrupt;
  g6lc_storamic_pkg::axil_req_t creq;
  g6lc_storamic_pkg::axil_resp_t cresp;
  int cacc[4];
  always @(posedge clk) begin
    if (creq.aw_valid && cresp.aw_ready) cacc[0]++;
    if (creq.w_valid && cresp.w_ready) cacc[1]++;
    if (creq.ar_valid && cresp.ar_ready) cacc[2]++;
  end

  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t MCfg = '{
    Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
    MaxSticks: Slots, RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0};

  g6lc_storamic_top #(
    .Cfg(MCfg), .DataWidth(DataWidth), .Slots(Slots), .Regions(NRegions),
    .SlotMap(SMap), .RegionMap(RMap), .BootMapEn(BootMapEn),
    .req_t(req_t), .resp_t(resp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .req_i(req), .resp_o(resp),
    .ctrl_req_i(creq), .ctrl_resp_o(cresp), .init_done_o(), .service_ready_o(),
    .media_ready_o(), .pad_o(),
    .source_i(8'h42), .reset_generation_i(32'h1), .model_ready_o(),
    .sequence_exhausted_o(), .faults_o(), .events_o(),
    .mem_ready_i(mem_ready), .mem_req_o(mem_req), .mem_gnt_i(mem_gnt),
    .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata),
    .mem_be_o(mem_be), .mem_tag_o(mem_tag_o), .mem_slot_o(mem_slot),
    .mem_rvalid_i(mem_rvalid), .mem_rdata_i(mem_rdata),
    .mem_error_i(mem_error), .mem_tag_i(mem_tag_i),
    .irq_o(), .stray_i(stray)
  );

  g6lc_storamic_slot_mux #(.Slots(Slots), .DataWidth(DataWidth), .SlotMap(SMap))
  mux (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0),
    .mem_ready_o(mem_ready), .mem_req_i(mem_req), .mem_slot_i(mem_slot),
    .mem_gnt_o(mem_gnt), .mem_we_i(mem_we), .mem_addr_i(mem_addr),
    .mem_wdata_i(mem_wdata), .mem_be_i(mem_be), .mem_tag_i(mem_tag_o),
    .mem_rvalid_o(mem_rvalid), .mem_rdata_o(mem_rdata),
    .mem_error_o(mem_error), .mem_tag_o(mem_tag_i),
    .slot_ready_i(s_ready), .slot_req_o(s_req), .slot_gnt_i(s_gnt),
    .slot_we_o(s_we), .slot_addr_o(s_addr), .slot_wdata_o(s_wdata),
    .slot_be_o(s_be), .slot_tag_o(s_tag_o),
    .slot_rvalid_i(s_rvalid), .slot_rdata_i(s_rdata),
    .slot_error_i(s_error), .slot_tag_i(s_tag_i), .stray_o(stray)
  );

  for (genvar i = 0; i < Slots; i++) begin : gen_ram
    g6lc_storamic_sram_model #(
      .DataWidth(DataWidth), .Capacity(32'(SMap[i].ram_bytes))
    ) ram (
      .clk_i(clk), .rst_ni(rst_n), .available_i(available[i]),
      .grant_enable_i(1'b1), .reply_enable_i(1'b1), .error_i(1'b0),
      .ready_o(s_ready[i]), .req_i(s_req[i]), .gnt_o(s_gnt[i]), .we_i(s_we),
      .addr_i(s_addr), .data_i(s_wdata), .be_i(s_be), .tag_i(s_tag_o),
      .rvalid_o(model_rvalid[i]), .data_o(model_data[i]), .error_o(s_error[i]),
      .tag_o(model_tag[i])
    );
    assign s_rvalid[i] = model_rvalid[i] || inject_stray[i];
    assign s_rdata[i] = model_data[i];
    assign s_tag_i[i] = model_tag[i];
  end

  // ---- independent oracle -------------------------------------------------
  byte unsigned expected [MaxSlots][MaxCap];
  int unsigned wr_cmds [MaxSlots], rd_cmds [MaxSlots];
  int unsigned stray_pulses, aw_count, ar_count, gcnt;

  initial begin
    for (int s = 0; s < MaxSlots; s++)
      for (int i = 0; i < MaxCap; i++)
        expected[s][i] = 8'((i * 13) ^ (i >> 8) ^ 'h5a);
    for (int s = 0; s < MaxSlots; s++) begin
      wr_cmds[s] = 0; rd_cmds[s] = 0;
    end
  end

  always @(posedge clk) begin
    for (int s = 0; s < Slots; s++)
      if (rst_n && s_req[s] && s_gnt[s]) begin
        if (s_we) begin
          wr_cmds[s]++;
          for (int i = 0; i < Bytes; i++)
            if (s_be[i] && s_addr + 64'(i) < 64'(MaxCap))
              expected[s][32'(s_addr) + i] = s_wdata[8*i +: 8];
        end else rd_cmds[s]++;
      end
    if (stray) stray_pulses++;
    if (mem_req && mem_gnt) gcnt++;
    if (req.aw_valid && resp.aw_ready) aw_count++;
    if (req.ar_valid && resp.ar_ready) ar_count++;
  end

  task automatic tick; @(negedge clk); endtask
  task automatic section(input string n);
    $display("STORAMIC_MAP_SECTION %s", n);
  endtask

  task automatic drive_aw(input logic [63:0] a, input int len, input int sz,
      input logic [1:0] b, input string tag);
    int t;
    req.aw = '0; req.aw.id = id_t'(1); req.aw.addr = a;
    req.aw.len = 8'(len - 1); req.aw.size = 3'(sz); req.aw.burst = b;
    req.aw_valid = 1;
    t = 0;
    while (!resp.aw_ready && t < 800) begin t++; @(negedge clk); end
    if (!resp.aw_ready) begin
      $display("STORAMIC_MAP_AX_WAIT %s", tag);
      $fatal(1, "STORAMIC_MAP_AX_WAIT");
    end
    @(posedge clk); @(negedge clk);
    req.aw_valid = 0;
  endtask

  task automatic drive_ar(input logic [63:0] a, input int len, input int sz,
      input logic [1:0] b, input string tag);
    int t;
    req.ar = '0; req.ar.id = id_t'(1); req.ar.addr = a;
    req.ar.len = 8'(len - 1); req.ar.size = 3'(sz); req.ar.burst = b;
    req.ar_valid = 1;
    t = 0;
    while (!resp.ar_ready && t < 800) begin t++; @(negedge clk); end
    if (!resp.ar_ready) begin
      $display("STORAMIC_MAP_AX_WAIT %s", tag);
      $fatal(1, "STORAMIC_MAP_AX_WAIT");
    end
    @(posedge clk); @(negedge clk);
    req.ar_valid = 0;
  endtask

  task automatic wait_beat(input string tag);
    int t;
    t = 0;
    while (!resp.w_ready && t < 800) begin t++; @(negedge clk); end
    if (!resp.w_ready) begin
      $display("STORAMIC_MAP_W_WAIT %s", tag);
      $fatal(1, "STORAMIC_MAP_W_WAIT");
    end
    @(posedge clk); @(negedge clk);
  endtask

  task automatic wait_grant(input string tag);
    int snap, t;
    snap = gcnt; t = 0;
    while (gcnt == snap && t < 800) begin t++; @(negedge clk); end
    if (gcnt == snap) begin
      $display("STORAMIC_MAP_GRANT_WAIT %s", tag);
      $fatal(1, "STORAMIC_MAP_GRANT_WAIT");
    end
  endtask

  task automatic wait_rvalid(input string tag);
    int t;
    t = 0;
    while (!resp.r_valid && t < 800) begin t++; @(negedge clk); end
    if (!resp.r_valid) begin
      $display("STORAMIC_MAP_R_WAIT %s", tag);
      $fatal(1, "STORAMIC_MAP_R_WAIT");
    end
  endtask

  task automatic wait_bvalid(input string tag);
    int t;
    t = 0;
    while (!resp.b_valid && t < 800) begin t++; @(negedge clk); end
    if (!resp.b_valid) begin
      $display("STORAMIC_MAP_B_WAIT %s", tag);
      $fatal(1, "STORAMIC_MAP_B_WAIT");
    end
  endtask

  task automatic cwr(input logic [31:0] a, input logic [31:0] d,
                     output logic [1:0] rsp);
    int s0;
    s0 = cacc[0];
    creq.aw.addr = a; creq.aw_valid = 1;
    do @(negedge clk); while (cacc[0] == s0);
    creq.aw_valid = 0;
    s0 = cacc[1];
    creq.w.data = d; creq.w.strb = '1; creq.w_valid = 1;
    do @(negedge clk); while (cacc[1] == s0);
    creq.w_valid = 0;
    creq.b_ready = 1;
    while (!cresp.b_valid) @(negedge clk);
    rsp = cresp.b.resp;
    tick(); creq.b_ready = 0;
  endtask

  task automatic crd(input logic [31:0] a, output logic [31:0] d,
                     output logic [1:0] rsp);
    int s0;
    s0 = cacc[2];
    creq.ar.addr = a; creq.ar_valid = 1;
    do @(negedge clk); while (cacc[2] == s0);
    creq.ar_valid = 0;
    creq.r_ready = 1;
    while (!cresp.r_valid) @(negedge clk);
    d = cresp.r.data; rsp = cresp.r.resp;
    tick(); creq.r_ready = 0;
  endtask

  // ST-010B: stage the parametric map over AXI-Lite and request commit.
  task automatic program_map(input string tag);
    logic [1:0] cr;
    logic [31:0] a;
    for (int i = 0; i < NRegions; i++) begin
      a = 32'h400 + 32'h20 * i;
      cwr(a + 0,  RMap[i].base[31:0], cr);
      cwr(a + 4,  RMap[i].base[63:32], cr);
      cwr(a + 8,  RMap[i].bytes[31:0], cr);
      cwr(a + 12, RMap[i].bytes[63:32], cr);
      cwr(a + 16, RMap[i].offset[31:0], cr);
      cwr(a + 20, RMap[i].offset[63:32], cr);
      cwr(a + 24, {24'h0, RMap[i].slot}, cr);
      cwr(a + 28, {29'h0, RMap[i].write, RMap[i].read, RMap[i].valid}, cr);
    end
    cwr(32'h020, 32'h1, cr);
    if (cr != 2'b00) $fatal(1, "STORAMIC_MAP_COMMIT_SLVERR %s", tag);
  endtask

  task automatic write_burst(input logic [63:0] a, input int len, input int sz,
      input logic [1:0] burst, input logic [Bytes-1:0] strb,
      output logic [1:0] code, input string tag);
    drive_aw(a, len, sz, burst, tag);
    for (int i = 0; i < len; i++) begin
      req.w = '0; req.w.data = '1; req.w.strb = strb;
      req.w.last = i == len - 1; req.w_valid = 1;
      wait_beat(tag);
      req.w_valid = 0;
    end
    wait_bvalid(tag);
    code = resp.b.resp;
    req.b_ready = 1; tick(); req.b_ready = 0;
  endtask

  task automatic read_burst(input logic [63:0] a, input int len, input int sz,
      input logic [1:0] burst, output logic [1:0] code, input string tag);
    drive_ar(a, len, sz, burst, tag);
    for (int i = 0; i < len; i++) begin
      wait_rvalid(tag);
      code = resp.r.resp;
      req.r_ready = 1; tick(); req.r_ready = 0;
    end
  endtask

  task automatic expect_read_bytes(input logic [63:0] a, input int slot,
      input logic [63:0] off, input int nbytes);
    int left, wg;
    logic [63:0] cur, pos;
    left = nbytes; cur = a; pos = off;
    while (left > 0) begin
      drive_ar(cur, 1, $clog2(Bytes), 2'b01,
               "expect_read");
      wait_rvalid("expect_read");
      if (resp.r.resp != 2'b00) $fatal(1, "STORAMIC_MAP_READ_REFUSED");
      for (int i = 0; i < Bytes && left > 0; i++) begin
        if (expected[slot][32'(pos)] != resp.r.data[8*i +: 8]) begin
          if (corrupt) $fatal(1, "STORAMIC_MAP_ORACLE_NEGATIVE");
          else $fatal(1, "STORAMIC_MAP_READ_DATA slot=%0d off=%0d", slot, pos);
        end
        pos++; left--; cur++;
      end
      req.r_ready = 1; tick(); req.r_ready = 0;
    end
  endtask

  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "STORAMIC_MAP_TIMEOUT");
  end

  initial begin
    logic [1:0] code;
    int wr0, wr1, wr2, rd0, rd1, rd2, snap;
    req = '0; corrupt = 0; available = '1; inject_stray = '0;
    stray_pulses = 0; aw_count = 0; ar_count = 0; gcnt = 0;
    repeat (3) tick();
    rst_n = 1; tick();
    if ($test$plusargs("oracle_negative")) corrupt = 1;
    creq = '0;

    if (!BootMapEn) begin
      int g0;
      logic [31:0] md;
      logic [1:0] cr;
      section("rtmap-precommit");
      // Every data access is refused with zero slot commands pre-commit.
      g0 = gcnt;
      write_burst(64'h0, 1, $clog2(Bytes), 2'b01, '1, code, "w-precommit");
      if (code != 2 || gcnt != g0)
        $fatal(1, "STORAMIC_MAP_PRECOMMIT code=%0d gcnt=%0d", code, gcnt);
      program_map("rtmap");
      crd(32'h020, md, cr);
      begin : rtwait
        int g;
        g = 0;
        while (!md[2] && g < 400) begin
          crd(32'h020, md, cr); g++;
        end
        if (!md[2] || md[12:8] != 5'd0)
          $fatal(1, "STORAMIC_MAP_COMMIT_STATUS %h", md);
      end
    end

    section("single-r0");
    write_burst(64'h0, 1, $clog2(Bytes), 2'b01, '1, code, "w-r0");
    if (code != 0) $fatal(1, "STORAMIC_MAP_W0");
    expect_read_bytes(64'h0, 0, 64'h0, Bytes);

    section("single-r1");
    write_burst(64'h800, 1, $clog2(Bytes), 2'b01, '1, code, "w-r1");
    if (code != 0) $fatal(1, "STORAMIC_MAP_W1");
    expect_read_bytes(64'h800, SlotA, 64'(OffA), Bytes);

    section("incr-cross");
    // Beat0 ends r0 (slot0 off 0x800-Bytes), beat1 enters r1 (slotA, OffA).
    write_burst(64'h800 - Bytes, 2, $clog2(Bytes), 2'b01, '1, code, "cross");
    if (code != 0) $fatal(1, "STORAMIC_MAP_CROSS_W");
    expect_read_bytes(64'h800 - Bytes, 0, 64'h800 - Bytes, Bytes);
    expect_read_bytes(64'h800, SlotA, 64'(OffA), Bytes);

    section("second-perm");
    wr0 = wr_cmds[0]; wr1 = Slots > 1 ? wr_cmds[1] : 0;
    wr2 = Slots > 2 ? wr_cmds[2] : 0;
    write_burst(64'hC00 - Bytes, 2, $clog2(Bytes), 2'b01, '1, code, "perm2");
    if (code != 2'b10) $fatal(1, "STORAMIC_MAP_SECOND_PERM");
    if (wr_cmds[0] != wr0 || (Slots > 1 && wr_cmds[1] != wr1) ||
        (Slots > 2 && wr_cmds[2] != wr2))
      $fatal(1, "STORAMIC_MAP_SECOND_SIDE");

    section("hole-extent");
    wr0 = wr_cmds[0]; wr1 = Slots > 1 ? wr_cmds[1] : 0;
    rd0 = rd_cmds[0]; rd1 = Slots > 1 ? rd_cmds[1] : 0;
    // r3 (WO) at 0x1800..0x1C00 then hole: write denied at r3 -> SLVERR.
    write_burst(64'h1C00 - Bytes, 2, $clog2(Bytes), 2'b01, '1, code, "hole-w");
    if (code != 2'b10) $fatal(1, "STORAMIC_MAP_HOLE_WRESP");
    // r2 (RO) at 0xC00..0x1000 then hole: read beat1 falls in hole -> SLVERR.
    read_burst(64'h1000 - Bytes, 2, $clog2(Bytes), 2'b01, code, "hole-r");
    if (code != 2'b10) $fatal(1, "STORAMIC_MAP_HOLE_RRESP");
    if (wr_cmds[0] != wr0 || (Slots > 1 && wr_cmds[1] != wr1) ||
        rd_cmds[0] != rd0 || (Slots > 1 && rd_cmds[1] != rd1))
      $fatal(1, "STORAMIC_MAP_HOLE_SIDE");

    section("perm-refusals");
    wr0 = wr_cmds[0]; rd0 = rd_cmds[0];
    write_burst(64'hC00, 1, $clog2(Bytes), 2'b01, '1, code, "wro");
    if (code != 2'b10) $fatal(1, "STORAMIC_MAP_WRO");
    read_burst(64'h1800, 1, $clog2(Bytes), 2'b01, code, "rwo");
    if (code != 2'b10) $fatal(1, "STORAMIC_MAP_RWO");
    if (wr_cmds[0] != wr0 || rd_cmds[0] != rd0)
      $fatal(1, "STORAMIC_MAP_PERM_SIDE");

    section("narrow");
    // Single-byte transfer: strobe only the addressed lane.
    write_burst(64'h40, 1, 0, 2'b01, Bytes'(8'h1) << (64'h40 & (Bytes - 1)),
                code, "narrow");
    if (code != 0) $fatal(1, "STORAMIC_MAP_NARROW");

    section("fixed-wrap");
    write_burst(64'h80, 4, $clog2(Bytes), 2'b00, '1, code, "fixed");
    if (code != 0) $fatal(1, "STORAMIC_MAP_FIXED");
    // WRAP len 4 size min(3, log2(Bytes)) starting unit-aligned inside window;
    // each beat gets the strobe for its own wrapped unit.
    begin
      logic [63:0] waddr [4];
      waddr = '{64'h2E8, 64'h2F0, 64'h2F8, 64'h2E0};
      drive_aw(64'h2E8, 4, ($clog2(Bytes) < 3 ? $clog2(Bytes) : 3), 2'b10,
               "wrap");
      for (int k = 0; k < 4; k++) begin
        req.w = '0; req.w.data = '1;
        req.w.strb = Bytes'(8'hFF) << (waddr[k] & (Bytes - 1));
        req.w.last = k == 3; req.w_valid = 1;
        wait_beat("wrap");
        req.w_valid = 0;
      end
      wait_bvalid("wrap");
      code = resp.b.resp;
      req.b_ready = 1; tick(); req.b_ready = 0;
    end
    if (code != 0) $fatal(1, "STORAMIC_MAP_WRAP");
    // Oracle-verified WRAP read order: 0x2E8 -> 0x2F0 -> 0x2F8 -> 0x2E0.
    drive_ar(64'h2E8, 4,
             ($clog2(Bytes) < 3 ? $clog2(Bytes) : 3), 2'b10, "wrap-rd");
    begin
      logic [63:0] order [4];
      order = '{64'h2E8, 64'h2F0, 64'h2F8, 64'h2E0};
      for (int k = 0; k < 4; k++) begin
        int lane0;
        lane0 = int'(order[k] & (Bytes - 1));
        wait_rvalid("wrap-rd");
        for (int i = 0; i < 8; i++)
          if (expected[0][32'(order[k]) + i] != resp.r.data[8*(lane0+i) +: 8])
            $fatal(1, "STORAMIC_MAP_WRAP_ORDER k=%0d", k);
        req.r_ready = 1; tick(); req.r_ready = 0;
      end
    end

    section("stray");
    // Wrong-slot completion while in flight (Slots>=2), then stray while idle.
    if (Slots >= 2) begin
      snap = gcnt;
      drive_ar(64'h0, 1, $clog2(Bytes),
               2'b01, "stray-ar");
      wait_grant("stray");
      inject_stray[1] = 1;
      tick();
      if (!stray) tick();
      inject_stray[1] = 0;
      tick();
      if (stray_pulses != 1) $fatal(1, "STORAMIC_MAP_STRAY_COUNT");
      wait_rvalid("stray");
      if (resp.r.resp != 0) $fatal(1, "STORAMIC_MAP_STRAY_RETIRE");
      req.r_ready = 1; tick(); req.r_ready = 0;
    end
    // Stray on slot 0 with no command in flight: pulse, no response.
    inject_stray[0] = 1;
    tick(); tick();
    inject_stray[0] = 0;
    if (resp.r_valid || resp.b_valid) $fatal(1, "STORAMIC_MAP_STRAY_RESP");
    if (stray_pulses != (Slots >= 2 ? 2 : 1))
      $fatal(1, "STORAMIC_MAP_STRAY_IDLE");

    if (Slots >= 4) begin
      for (int k = 3; k < Slots; k++) begin
        section("extra-slot");
        write_burst(64'h4000 + 64'h400 * 64'(k - 3), 1, $clog2(Bytes), 2'b01,
                    '1, code, "extra");
        if (code != 0) $fatal(1, "STORAMIC_MAP_EXTRA_W k=%0d", k);
        expect_read_bytes(64'h4000 + 64'h400 * 64'(k - 3), k, 64'h0, Bytes);
      end
    end

    if (Slots >= 2) begin
      section("top-of-space");
      write_burst(64'hFFFF_FFFF_FFFF_FE00, 1, $clog2(Bytes), 2'b01, '1, code,
                  "top");
      if (code != 0) $fatal(1, "STORAMIC_MAP_TOP_W");
      expect_read_bytes(64'hFFFF_FFFF_FFFF_FE00, SlotB, OffC, Bytes);
    end

    section("not-ready");
    available[0] = 0; tick();
    write_burst(64'h0, 1, $clog2(Bytes), 2'b01, '1, code, "nrdy");
    if (code != 2'b10) $fatal(1, "STORAMIC_MAP_NOTREADY");
    available[0] = 1; tick();

    section("backpressure");
    drive_aw(64'h100, 1, $clog2(Bytes),
             2'b01, "bp-w");
    req.w = '0; req.w.data = '1; req.w.strb = '1; req.w.last = 1; req.w_valid = 1;
    wait_beat("bp-w");
    req.w_valid = 0;
    repeat (40) tick();
    if (!resp.b_valid) $fatal(1, "STORAMIC_MAP_B_HOLD");
    req.b_ready = 1; tick(); req.b_ready = 0;
    drive_ar(64'h100, 1, $clog2(Bytes),
             2'b01, "bp-r");
    repeat (40) tick();
    if (!resp.r_valid) $fatal(1, "STORAMIC_MAP_R_HOLD");
    req.r_ready = 1; tick(); req.r_ready = 0;

    section("reset-mid");
    snap = gcnt;
    drive_ar(64'h0, 4, $clog2(Bytes),
             2'b01, "rst-mid");
    wait_grant("rst-mid");
    rst_n = 0; repeat (3) tick(); rst_n = 1; tick();
    req = '0;
    repeat (4) tick();
    if (!BootMapEn) begin
      int g0, g;
      logic [31:0] md;
      logic [1:0] cr;
      // Reset discards the committed runtime map: refuse again, recommit.
      g0 = gcnt;
      read_burst(64'h0, 1, $clog2(Bytes), 2'b01, code, "r-postreset");
      if (code != 2'b10 || gcnt != g0)
        $fatal(1, "STORAMIC_MAP_POSTRESET code=%0d gcnt=%0d", code, gcnt);
      program_map("rtmap-reset");
      g = 0;
      crd(32'h020, md, cr);
      while (!md[2] && g < 400) begin
        crd(32'h020, md, cr); g++;
      end
      if (!md[2] || md[12:8] != 5'd0)
        $fatal(1, "STORAMIC_MAP_RECOMMIT_STATUS %h", md);
    end

    section("oracle");
    if (corrupt) expected[0][0] = expected[0][0] ^ 8'hff;
    expect_read_bytes(64'h0, 0, 64'h0, Bytes);

    $display("STORAMIC_MAP_PASS slots=%0d width=%0d regions=%0d stray=%0d",
             Slots, DataWidth, NRegions, stray_pulses);
    $finish;
  end
endmodule

// Synthesis wrapper: MapEn=1 frontend + mux with a 3-slot map at 64-bit.
module g6lc_storamic_map_synth (
  input logic clk_i, rst_ni, testmode_i,
  input g6lc_storamic_pkg::axi_req_t req_i,
  output g6lc_storamic_pkg::axi_resp_t resp_o,
  input logic [2:0] slot_ready_i,
  output logic [2:0] slot_req_o,
  input logic [2:0] slot_gnt_i,
  output logic slot_we_o,
  output logic [63:0] slot_addr_o,
  output logic [63:0] slot_wdata_o,
  output logic [7:0] slot_be_o,
  output g6lc_storamic_pkg::txn_id_t slot_tag_o,
  input logic [2:0] slot_rvalid_i,
  input logic [2:0][63:0] slot_rdata_i,
  input logic [2:0] slot_error_i,
  input g6lc_storamic_pkg::txn_id_t [2:0] slot_tag_i,
  output logic stray_o
);
  import g6lc_storamic_region_pkg::*;
  localparam slot_map_t SMap = '{
    0: '{present: 1'b1, identity: 32'h1, ram_bytes: 64'h4000, reserved_bytes: '0},
    1: '{present: 1'b1, identity: 32'h2, ram_bytes: 64'h8000, reserved_bytes: '0},
    2: '{present: 1'b1, identity: 32'h3, ram_bytes: 64'h6000, reserved_bytes: '0},
    default: '0};
  localparam region_map_t RMap = '{
    0: '{valid: 1'b1, base: 64'h0, bytes: 64'h800, slot: 8'd0,
        slot_identity: 32'h1, offset: 64'h0, read: 1'b1, write: 1'b1},
    1: '{valid: 1'b1, base: 64'h800, bytes: 64'h800, slot: 8'd1,
        slot_identity: 32'h2, offset: 64'h0, read: 1'b1, write: 1'b1},
    2: '{valid: 1'b1, base: 64'h1000, bytes: 64'h800, slot: 8'd2,
        slot_identity: 32'h3, offset: 64'h0, read: 1'b1, write: 1'b1},
    default: '0};
  localparam g6lc_storamic_cfg_pkg::storamic_cfg_t MCfg = '{
    Enable: 1'b1, Profile: g6lc_storamic_cfg_pkg::ProfileMapped,
    MaxSticks: 3, RequestedMediaCaps: '0, ModelBase: '0, ModelBytes: '0};
  logic mem_ready, mem_req, mem_gnt, mem_we, mem_rvalid, mem_error;
  logic [63:0] mem_addr, mem_wdata, mem_rdata;
  logic [7:0] mem_be, mem_slot;
  g6lc_storamic_pkg::txn_id_t mem_tag_o, mem_tag_i;
  g6lc_storamic_top #(
    .Cfg(MCfg), .DataWidth(64), .SeqWidth(32), .Slots(3), .Regions(3),
    .SlotMap(SMap), .RegionMap(RMap),
    .req_t(g6lc_storamic_pkg::axi_req_t),
    .resp_t(g6lc_storamic_pkg::axi_resp_t)
  ) dut (
    .clk_i, .rst_ni, .testmode_i, .req_i(req_i), .resp_o(resp_o),
    .ctrl_req_i('0), .ctrl_resp_o(), .init_done_o(), .service_ready_o(),
    .media_ready_o(), .pad_o(),
    .source_i('0), .reset_generation_i('0), .model_ready_o(),
    .sequence_exhausted_o(), .faults_o(), .events_o(),
    .mem_ready_i(mem_ready), .mem_req_o(mem_req), .mem_gnt_i(mem_gnt),
    .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_wdata),
    .mem_be_o(mem_be), .mem_tag_o(mem_tag_o), .mem_slot_o(mem_slot),
    .mem_rvalid_i(mem_rvalid), .mem_rdata_i(mem_rdata),
    .mem_error_i(mem_error), .mem_tag_i(mem_tag_i), .irq_o(), .stray_i(1'b0)
  );
  g6lc_storamic_slot_mux #(.Slots(3), .DataWidth(64), .SlotMap(SMap)) mux (
    .clk_i, .rst_ni, .testmode_i,
    .mem_ready_o(mem_ready), .mem_req_i(mem_req), .mem_slot_i(mem_slot),
    .mem_gnt_o(mem_gnt), .mem_we_i(mem_we), .mem_addr_i(mem_addr),
    .mem_wdata_i(mem_wdata), .mem_be_i(mem_be), .mem_tag_i(mem_tag_o),
    .mem_rvalid_o(mem_rvalid), .mem_rdata_o(mem_rdata),
    .mem_error_o(mem_error), .mem_tag_o(mem_tag_i),
    .slot_ready_i, .slot_req_o, .slot_gnt_i,
    .slot_we_o, .slot_addr_o, .slot_wdata_o, .slot_be_o, .slot_tag_o,
    .slot_rvalid_i, .slot_rdata_i, .slot_error_i, .slot_tag_i, .stray_o
  );
endmodule
