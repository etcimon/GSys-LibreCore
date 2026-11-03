// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

module tb_g6lc_storamic_model #(
  parameter int unsigned DataWidth = 64,
  parameter int unsigned IdWidth = 8,
  parameter int unsigned SeqWidth = 32,
  parameter logic [63:0] BaseAddr = 64'h8000_0000,
  parameter int unsigned Capacity = 8192,
  parameter bit SequenceTest = 1'b0,
  parameter bit BadGeometry = 1'b0,
  parameter bit UseTopProfile = 1'b0,
  parameter int unsigned TopProfile = 2,
  parameter bit TopEnable = 1'b1,
  parameter int unsigned TopSticks = 1,
  parameter logic [31:0] TopRequestedCaps = 0
);
  import g6lc_storamic_pkg::txn_id_t;
  import g6lc_storamic_pkg::model_events_t;
  localparam int unsigned Bytes = DataWidth / 8;
  localparam int unsigned FullSize = $clog2(Bytes);
  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [63:0] addr;
    logic [7:0] len;
    logic [2:0] size;
    logic [1:0] burst;
    logic lock;
    logic [3:0] cache;
    logic [2:0] prot;
    logic [3:0] qos, region;
    logic user;
  } addr_t;
  typedef struct packed {
    logic [DataWidth-1:0] data;
    logic [Bytes-1:0] strb;
    logic last, user;
  } w_t;
  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [1:0] resp;
    logic user;
  } b_t;
  typedef struct packed {
    logic [IdWidth-1:0] id;
    logic [DataWidth-1:0] data;
    logic [1:0] resp;
    logic last, user;
  } r_t;
  typedef struct packed {
    addr_t aw;
    logic aw_valid;
    w_t w;
    logic w_valid, b_ready;
    addr_t ar;
    logic ar_valid, r_ready;
  } req_t;
  typedef struct packed {
    logic aw_ready, w_ready;
    b_t b;
    logic b_valid, ar_ready;
    r_t r;
    logic r_valid;
  } resp_t;
  logic clk = 0;
  logic rst_n = 0;
  always #5 clk = ~clk;
  req_t req;
  resp_t resp;
  model_events_t events;
  logic service_ready, exhausted;
  logic [2:0] faults;
  logic available = 1, grant_enable = 1, reply_enable = 1, inject_error = 0;
  logic mem_ready, mem_req, mem_gnt, mem_we, model_rvalid, model_error;
  logic [63:0] mem_addr;
  logic [DataWidth-1:0] mem_data, model_data;
  logic [Bytes-1:0] mem_be;
  txn_id_t mem_tag, model_tag, stale_tag, new_tag;
  logic inject_stale = 0;
  bit corrupt_data;
  initial corrupt_data = $test$plusargs("MODEL_CORRUPT");
  logic [31:0] generation = 0;
  byte unsigned expected [Capacity];
  int unsigned commands = 0;
  logic [Bytes-1:0] alternating;
  bit trace_concurrent = 0;
  bit verbose_concurrent;
  initial verbose_concurrent = $test$plusargs("STORAMIC_TRACE");
  time concurrent_started;
  int unsigned concurrent_aw = 0, concurrent_w = 0, concurrent_b = 0;
  int unsigned concurrent_ar = 0, concurrent_r = 0;
  int unsigned concurrent_mem_reads = 0, concurrent_mem_writes = 0;
  g6lc_storamic_pkg::axil_req_t top_ctrl_req;
  g6lc_storamic_pkg::axil_resp_t top_ctrl_resp;

  if (UseTopProfile) begin : gen_top
    localparam int unsigned Slots = TopSticks > 0 ? TopSticks : 1;
    localparam g6lc_storamic_cfg_pkg::storamic_cfg_t Cfg = '{
      Enable: TopEnable, Profile: g6lc_storamic_cfg_pkg::profile_t'(TopProfile),
      MaxSticks: TopSticks, RequestedMediaCaps: TopRequestedCaps,
      ModelBase: BaseAddr, ModelBytes: BadGeometry ? 64'd0 : 64'(Capacity)
    };
    logic initialized, model_ready;
    logic [Slots-1:0] media_ready;
    g6lc_storamic_pad_pkg::pad_out_t [Slots-1:0] pads;
    g6lc_storamic_top #(
      .Cfg(Cfg), .DataWidth(DataWidth), .SeqWidth(SeqWidth),
      .req_t(req_t), .resp_t(resp_t)
    ) dut (
      .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .req_i(req), .resp_o(resp),
      .ctrl_req_i(top_ctrl_req), .ctrl_resp_o(top_ctrl_resp),
      .init_done_o(initialized), .model_ready_o(model_ready),
      .media_ready_o(media_ready), .pad_o(pads),
      .source_i(8'h3a), .reset_generation_i(generation),
      .service_ready_o(service_ready), .sequence_exhausted_o(exhausted),
      .faults_o(faults), .events_o(events),
      .mem_ready_i(mem_ready), .mem_req_o(mem_req), .mem_gnt_i(mem_gnt),
      .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_data),
      .mem_be_o(mem_be), .mem_tag_o(mem_tag),
      .mem_rvalid_i(inject_stale || model_rvalid),
      .mem_rdata_i(inject_stale ? {DataWidth{1'b1}} : (model_data ^ DataWidth'(corrupt_data))),
      .mem_error_i(inject_stale ? 1'b0 : model_error),
      .mem_tag_i(inject_stale ? stale_tag : model_tag)
    );
    always @(posedge clk) begin
      assert (initialized == model_ready &&
              model_ready == (service_ready && mem_ready) && media_ready == 0)
        else $fatal(1, "STORAMIC_MODEL_READINESS");
      for (int slot = 0; slot < Slots; slot++)
        assert (pads[slot] == g6lc_storamic_pad_pkg::PadSafe)
          else $fatal(1, "STORAMIC_MODEL_PAD_UNSAFE");
    end
  end else begin : gen_component
    assign top_ctrl_resp = '0;
    g6lc_storamic_axi_memory #(
    .DataWidth(DataWidth), .SeqWidth(SeqWidth), .BaseAddr(BaseAddr),
    .RegionBytes(BadGeometry ? 64'd0 : 64'(Capacity)),
    .req_t(req_t), .resp_t(resp_t)
  ) dut (
    .clk_i(clk), .rst_ni(rst_n), .testmode_i(1'b0), .req_i(req), .resp_o(resp),
    .source_i(8'h3a), .reset_generation_i(generation),
    .service_ready_o(service_ready), .sequence_exhausted_o(exhausted),
    .faults_o(faults), .events_o(events),
    .mem_ready_i(mem_ready), .mem_req_o(mem_req), .mem_gnt_i(mem_gnt),
    .mem_we_o(mem_we), .mem_addr_o(mem_addr), .mem_wdata_o(mem_data),
    .mem_be_o(mem_be), .mem_tag_o(mem_tag),
    .mem_rvalid_i(inject_stale || model_rvalid),
    .mem_rdata_i(inject_stale ? {DataWidth{1'b1}} : (model_data ^ DataWidth'(corrupt_data))),
    .mem_error_i(inject_stale ? 1'b0 : model_error),
    .mem_tag_i(inject_stale ? stale_tag : model_tag)
    );
  end
  g6lc_storamic_sram_model #(.DataWidth(DataWidth), .Capacity(Capacity)) ram (
    .clk_i(clk), .rst_ni(rst_n), .available_i(available),
    .grant_enable_i(grant_enable), .reply_enable_i(reply_enable),
    .error_i(inject_error), .ready_o(mem_ready),
    .req_i(mem_req), .gnt_o(mem_gnt), .we_i(mem_we),
    .addr_i(mem_addr), .data_i(mem_data), .be_i(mem_be), .tag_i(mem_tag),
    .rvalid_o(model_rvalid), .data_o(model_data), .error_o(model_error), .tag_o(model_tag)
  );
  always @(posedge clk)
    if (rst_n && mem_req && mem_gnt) commands <= commands + 1;

  // Coverage and diagnostics use public signals for either implementation path.
  always @(posedge clk) begin
    if (rst_n && trace_concurrent) begin
      if (req.aw_valid && resp.aw_ready) concurrent_aw <= concurrent_aw + 1;
      if (req.w_valid && resp.w_ready) concurrent_w <= concurrent_w + 1;
      if (req.b_ready && resp.b_valid) concurrent_b <= concurrent_b + 1;
      if (req.ar_valid && resp.ar_ready) concurrent_ar <= concurrent_ar + 1;
      if (req.r_ready && resp.r_valid) concurrent_r <= concurrent_r + 1;
      if (mem_req && mem_gnt && mem_we)
        concurrent_mem_writes <= concurrent_mem_writes + 1;
      if (mem_req && mem_gnt && !mem_we)
        concurrent_mem_reads <= concurrent_mem_reads + 1;
      if (verbose_concurrent) begin
      if (req.aw_valid && resp.aw_ready)
        $display("MODEL_TRACE t=%0t AW addr=%h len=%0d refuse=%b ready=%b",
                 $time, req.aw.addr, req.aw.len, events.aw_refuse, mem_ready);
      if (req.w_valid && resp.w_ready)
        $display("MODEL_TRACE t=%0t W last=%b strb=%h user=%b data=%h protocol_error=%b",
                 $time, req.w.last, req.w.strb, req.w.user, req.w.data[7:0],
                 events.w_protocol_error);
      if (mem_req && mem_gnt)
        $display("MODEL_TRACE t=%0t MEM we=%b addr=%h tag=%h inject_error=%b",
                 $time, mem_we, mem_addr, mem_tag, inject_error);
      if (model_rvalid)
        $display("MODEL_TRACE t=%0t DONE err=%b tag=%h stale=%b",
                 $time, model_error, model_tag, events.stale_completion);
      if (resp.b_valid)
        $display("MODEL_TRACE t=%0t B resp=%b faults=%b", $time, resp.b.resp, faults);
      $fflush();
      end
    end
  end

  task automatic tick;
    @(negedge clk);
  endtask

  task automatic check_top_control;
    int unsigned before_commands;
    if (UseTopProfile) begin
      before_commands = commands;
      top_ctrl_req.ar_valid = 1;
      do @(posedge clk); while (!top_ctrl_resp.ar_ready);
      tick();
      top_ctrl_req.ar_valid = 0;
      while (!top_ctrl_resp.r_valid) tick();
      repeat (3) begin
        assert (top_ctrl_resp.r_valid && top_ctrl_resp.r.resp == 2'b10 &&
                top_ctrl_resp.r.data == 0)
          else $fatal(1, "STORAMIC_MODEL_CONTROL_REFUSAL");
        tick();
      end
      top_ctrl_req.r_ready = 1;
      tick();
      top_ctrl_req.r_ready = 0;
      assert (!top_ctrl_resp.r_valid && commands == before_commands)
        else $fatal(1, "STORAMIC_MODEL_CONTROL_SIDE_EFFECT");
    end
  endtask

  task automatic reset_front;
    rst_n = 0;
    req = '0;
    inject_stale = 0;
    generation++;
    repeat (3) tick();
    assert (!resp.r_valid && !resp.b_valid && !mem_req && !service_ready)
      else $fatal(1, "STORAMIC_MODEL_RESET_OUTPUT");
    rst_n = 1;
    tick();
    assert (service_ready && !resp.r_valid && !resp.b_valid)
      else $fatal(1, "STORAMIC_MODEL_RESET_STALE");
  endtask

  // Oracle uses byte addresses and division/remainder, never DUT helpers/state.
  function automatic longint unsigned byte_address(
      input longint unsigned start, input int beat, beats, size,
      input logic [1:0] burst);
    longint unsigned n, span, origin;
    n = 64'd1 << size;
    span = 64'(beats) * n;
    if (burst == 0 || beat == 0) return start;
    if (burst == 2) begin
      origin = (start / span) * span;
      return origin + ((start - origin + 64'(beat) * n) % span);
    end
    return (start / n) * n + 64'(beat) * n;
  endfunction

  function automatic logic [Bytes-1:0] byte_mask(
      input longint unsigned addr, input int size);
    longint unsigned n, first_lane, last_byte, word;
    logic [Bytes-1:0] result;
    n = 64'd1 << size;
    word = (addr / Bytes) * Bytes;
    first_lane = addr - word;
    // Inclusive bound remains representable for the last byte of 64-bit space.
    last_byte = (addr / n) * n + (n - 1);
    result = '0;
    for (int lane = 0; lane < Bytes; lane++)
      result[lane] = 64'(lane) >= first_lane && word + 64'(lane) <= last_byte;
    return result;
  endfunction

  function automatic logic [DataWidth-1:0] pattern(input byte seed, input int beat);
    logic [DataWidth-1:0] result;
    for (int lane = 0; lane < Bytes; lane++)
      result[8*lane +: 8] = 8'(int'(seed) + beat * 23 + lane * 7);
    return result;
  endfunction

  function automatic logic [DataWidth-1:0] expected_word(
      input longint unsigned addr, input int size);
    logic [DataWidth-1:0] result;
    logic [Bytes-1:0] mask;
    longint unsigned word;
    result = '0;
    mask = byte_mask(addr, size);
    word = (addr / Bytes) * Bytes;
    for (int lane = 0; lane < Bytes; lane++)
      if (mask[lane]) result[8*lane +: 8] = expected[int'(word + 64'(lane) - BaseAddr)];
    return result;
  endfunction

  task automatic send_aw(input longint unsigned address, input int beats, size,
                         input logic [1:0] burst, input bit lock = 0);
    req.aw = '0;
    req.aw.id = IdWidth'('h155);
    req.aw.addr = address;
    req.aw.len = 8'(beats - 1);
    req.aw.size = 3'(size);
    req.aw.burst = burst;
    req.aw.lock = lock;
    req.aw.user = 1;
    req.aw.cache = 'hb;
    req.aw.prot = 3'b101;
    req.aw.qos = 7;
    req.aw.region = 9;
    req.aw_valid = 1;
    do @(posedge clk); while (!resp.aw_ready);
    tick();
    req.aw_valid = 0;
  endtask

  task automatic send_ar(input longint unsigned address, input int beats, size,
                         input logic [1:0] burst, input bit lock = 0);
    req.ar = '0;
    req.ar.id = '1;
    req.ar.addr = address;
    req.ar.len = 8'(beats - 1);
    req.ar.size = 3'(size);
    req.ar.burst = burst;
    req.ar.lock = lock;
    req.ar.user = 1;
    req.ar.cache = 'hb;
    req.ar.prot = 3'b100;
    req.ar.qos = 7;
    req.ar.region = 9;
    req.ar_valid = 1;
    do @(posedge clk); while (!resp.ar_ready);
    tick();
    req.ar_valid = 0;
  endtask

  task automatic recv_read(
      input longint unsigned address, input int beats, size, input logic [1:0] burst,
      input logic [1:0] response = 0, input int stalls = 2);
    r_t saved;
    logic [DataWidth-1:0] word;
    for (int beat = 0; beat < beats; beat++) begin
      while (!resp.r_valid) tick();
      word = response == 0 ? expected_word(byte_address(address, beat, beats, size, burst), size) : '0;
      assert (resp.r.id == {IdWidth{1'b1}} && resp.r.user == 1 &&
              resp.r.resp == response && resp.r.last == (beat == beats - 1) &&
              resp.r.data == word)
        else $fatal(1, "STORAMIC_MODEL_READ addr=%h beat=%0d expected=%h got=%h resp=%b",
                    address, beat, word, resp.r.data, resp.r.resp);
      saved = resp.r;
      repeat (stalls) begin
        tick();
        assert (resp.r_valid && resp.r == saved && !resp.ar_ready)
          else $fatal(1, "STORAMIC_MODEL_R_STABILITY");
      end
      req.r_ready = 1;
      tick();
      req.r_ready = 0;
    end
  endtask

  task automatic read_burst(
      input longint unsigned address, input int beats, size, input logic [1:0] burst,
      input logic [1:0] response = 0, input int stalls = 2, input bit lock = 0);
    send_ar(address, beats, size, burst, lock);
    recv_read(address, beats, size, burst, response, stalls);
  endtask

  task automatic write_burst(
      input longint unsigned address, input int beats, size, input logic [1:0] burst,
      input byte seed, input logic [Bytes-1:0] keep = '1,
      input logic [1:0] response = 0, input int committed = -1,
      input int bad_last = -1, input int bad_strobe = -1,
      input bit bad_user = 0, input bit early = 0, input bit lock = 0);
    b_t saved;
    longint unsigned a, word;
    logic [Bytes-1:0] mask;
    logic [DataWidth-1:0] data;
    int commit_beats;
    if (early) begin
      req.w.data = pattern(seed, 0);
      req.w.strb = byte_mask(address, size) & keep;
      req.w.last = beats == 1;
      req.w.user = bad_user;
      req.w_valid = 1;
      repeat (3) begin
        tick();
        assert (!resp.w_ready) else $fatal(1, "STORAMIC_MODEL_W_WITHOUT_AW");
      end
    end
    send_aw(address, beats, size, burst, lock);
    if (!early) repeat (2) tick();
    for (int beat = 0; beat < beats; beat++) begin
      a = byte_address(address, beat, beats, size, burst);
      req.w.data = pattern(seed, beat);
      req.w.strb = byte_mask(a, size) & keep;
      if (beat == bad_strobe) req.w.strb[(int'(a % Bytes) + 1) % Bytes] = 1;
      req.w.last = (beat == beats - 1) ^ (beat == bad_last);
      req.w.user = bad_user;
      req.w_valid = 1;
      do @(posedge clk); while (!resp.w_ready);
      tick();
      req.w_valid = 0;
    end
    while (!resp.b_valid) tick();
    assert (resp.b.id == IdWidth'('h155) && resp.b.user == 1 && resp.b.resp == response)
      else $fatal(1, "STORAMIC_MODEL_WRITE_RESPONSE addr=%h beats=%0d size=%0d burst=%b seed=%h expected=%b got=%b id=%h user=%b faults=%b early=%b bad_last=%0d bad_strobe=%0d bad_user=%b",
                  address, beats, size, burst, seed, response, resp.b.resp,
                  resp.b.id, resp.b.user, faults, early, bad_last, bad_strobe, bad_user);
    saved = resp.b;
    repeat (3) begin
      tick();
      assert (resp.b_valid && resp.b == saved && !resp.aw_ready)
        else $fatal(1, "STORAMIC_MODEL_B_STABILITY");
    end
    req.b_ready = 1;
    tick();
    req.b_ready = 0;
    commit_beats = committed >= 0 ? committed : (response == 0 ? beats : 0);
    for (int beat = 0; beat < commit_beats; beat++) begin
      a = byte_address(address, beat, beats, size, burst);
      word = (a / Bytes) * Bytes;
      mask = byte_mask(a, size) & keep;
      data = pattern(seed, beat);
      for (int lane = 0; lane < Bytes; lane++)
        if (mask[lane]) expected[int'(word + 64'(lane) - BaseAddr)] = data[8*lane +: 8];
    end
  endtask

  initial begin : stimulus
    int before_commands;
    logic [63:0] stalled_addr;
    logic [DataWidth-1:0] stalled_data;
    logic [Bytes-1:0] stalled_be;
    txn_id_t stalled_tag;
    logic stalled_we;
    req = '0;
    // Keep initialization with the timed driver. The pinned simulator placed
    // declaration-initialized packed control mapping in initial-settle only.
    top_ctrl_req = '0;
    alternating = '0;
    for (int lane = 0; lane < Bytes; lane++) alternating[lane] = (lane % 2) == 0;
    for (int i = 0; i < Capacity; i++)
      expected[i] = 8'((i * 13) ^ (i >> 8) ^ 'h5a);
    reset_front();

    check_top_control();
    if (SequenceTest) begin
      assert (SeqWidth == 2) else $fatal(1, "STORAMIC_SEQUENCE_FIXTURE");
      before_commands = commands;
      read_burst(BaseAddr, 5, 0, 1, 2'b10);
      assert (commands == before_commands && !exhausted)
        else $fatal(1, "STORAMIC_SEQUENCE_PARTIAL_RESERVATION");
      write_burst(BaseAddr, 2, 0, 1, 'h43);
      read_burst(BaseAddr, 2, 0, 1);
      assert (exhausted) else $fatal(1, "STORAMIC_SEQUENCE_NOT_EXHAUSTED");
      before_commands = commands;
      read_burst(BaseAddr, 1, 0, 1, 2'b10);
      write_burst(BaseAddr, 1, 0, 1, 'hff, '1, 2'b10);
      assert (commands == before_commands && faults[2])
        else $fatal(1, "STORAMIC_SEQUENCE_REUSED");
      reset_front();
      read_burst(BaseAddr, 2, 0, 1);
      $display("STORAMIC_MODEL_SEQUENCE_PASS");
      $finish;
    end

    read_burst(BaseAddr, 4, FullSize, 1);
    write_burst(BaseAddr, 4, FullSize, 1, 'h31, '1, 0, -1, -1, -1, 0, 1);
    read_burst(BaseAddr, 4, FullSize, 1);
    write_burst(BaseAddr + 'h100 + Bytes - 1, 4, 0, 1, 'h52);
    read_burst(BaseAddr + 'h100 + Bytes - 1, 4, 0, 1);
    read_burst(BaseAddr + 'h100, 2, FullSize, 1);
    write_burst(BaseAddr + 'h200, 4, FullSize, 1, 'h78, alternating);
    read_burst(BaseAddr + 'h200, 4, FullSize, 1);
    write_burst(BaseAddr + 'h300, 4, FullSize, 0, 'h94);
    read_burst(BaseAddr + 'h300, 4, FullSize, 0);
    write_burst(BaseAddr + 'h400 + 3*Bytes, 16, FullSize, 2, 'ha7);
    read_burst(BaseAddr + 'h400 + 3*Bytes, 16, FullSize, 2);
    write_burst(BaseAddr + 'h800, 256, 0, 1, 'hba);
    read_burst(BaseAddr + 'h800, 256, 0, 1, 0, 0);
    write_burst(BaseAddr + 4095, 1, FullSize, 1, 'hcd);
    read_burst(BaseAddr + 4095, 1, FullSize, 1);
    write_burst(BaseAddr + Capacity - 1, 1, FullSize, 1, 'hde);
    read_burst(BaseAddr + Capacity - 1, 1, FullSize, 1);
    if (Bytes > 1) begin
      write_burst(BaseAddr + 'h80 + 1, 3, FullSize, 1, 'he2);
      read_burst(BaseAddr + 'h80 + 1, 3, FullSize, 1);
      write_burst(BaseAddr + 'hc0 + 1, 3, FullSize, 0, 'he7);
      read_burst(BaseAddr + 'hc0 + 1, 3, FullSize, 0);
    end
    before_commands = commands;
    write_burst(BaseAddr + 'h200, 4, FullSize, 1, 'hff, '0);
    assert (commands == before_commands) else $fatal(1, "STORAMIC_ZERO_STROBE_COMMAND");
    read_burst(BaseAddr + 'h200, 4, FullSize, 1);

    // Every pre-admission error must leave the memory command stream untouched.
    before_commands = commands;
    read_burst(BaseAddr - 1, 2, 0, 1, 2'b10);
    write_burst(BaseAddr + Capacity - Bytes, 2, FullSize, 1, 'hff, '1, 2'b10);
    read_burst(BaseAddr + Capacity - Bytes, 2, FullSize, 1, 2'b10);
    write_burst(BaseAddr + 4095, 2, 0, 1, 'hff, '1, 2'b10);
    read_burst(BaseAddr + 4095, 2, 0, 1, 2'b10);
    write_burst(BaseAddr, 17, 0, 0, 'hff, '1, 2'b10);
    read_burst(BaseAddr, 17, 0, 0, 2'b10);
    write_burst(BaseAddr, 3, 0, 2, 'hff, '1, 2'b10);
    read_burst(BaseAddr, 3, 0, 2, 2'b10);
    write_burst(BaseAddr, 2, 0, 3, 'hff, '1, 2'b10);
    read_burst(BaseAddr, 2, 0, 3, 2'b10);
    if (Bytes > 1) begin
      write_burst(BaseAddr + 1, 4, FullSize, 2, 'hff, '1, 2'b10);
      read_burst(BaseAddr + 1, 4, FullSize, 2, 2'b10);
    end
    if (FullSize < 7) begin
      write_burst(BaseAddr, 1, FullSize + 1, 1, 'hff, '1, 2'b10);
      read_burst(BaseAddr, 1, FullSize + 1, 1, 2'b10);
    end
    write_burst(BaseAddr, 1, 0, 1, 'hff, '1, 2'b10, 0, -1, -1, 0, 0, 1);
    read_burst(BaseAddr, 1, 0, 1, 2'b10, 2, 1);
    read_burst(BaseAddr + 64'h1_0000_0000, 1, 0, 1, 2'b10);
    write_burst(64'hffff_ffff_ffff_ffff, 2, 0, 1, 'hff, '1, 2'b10);
    read_burst(64'hffff_ffff_ffff_ffff, 2, 0, 1, 2'b10);
    assert (commands == before_commands) else $fatal(1, "STORAMIC_INVALID_SIDE_EFFECT");

    available = 0;
    tick();
    assert (service_ready && !mem_ready) else $fatal(1, "STORAMIC_UNREADY_SERVICE");
    before_commands = commands;
    write_burst(BaseAddr, 4, 0, 1, 'hff, '1, 2'b10);
    read_burst(BaseAddr, 4, 0, 1, 2'b10);
    assert (commands == before_commands) else $fatal(1, "STORAMIC_UNREADY_COMMAND");
    available = 1;
    tick();

    // Malformed W beats do not erase previously completed beats.
    write_burst(BaseAddr + 'ha00, 4, 0, 1, 'h33, '1, 2'b10, 0, 0);
    write_burst(BaseAddr + 'ha20, 4, 0, 1, 'h44, '1, 2'b10, 3, 3);
    write_burst(BaseAddr + 'ha40, 4, 0, 1, 'h55, '1, 2'b10, 0, -1, -1, 1);
    if (Bytes > 1)
      write_burst(BaseAddr + 'ha60, 4, 0, 1, 'h66, '1, 2'b10, 1, -1, 1);
    inject_error = 1;
    write_burst(BaseAddr + 'ha80, 4, 0, 1, 'h77, '1, 2'b10);
    read_burst(BaseAddr + 'ha80, 4, 0, 1, 2'b10);
    assert (faults[1]) else $fatal(1, "STORAMIC_MEMORY_ERROR_NOT_OBSERVED");
    inject_error = 0;
    read_burst(BaseAddr + 'ha00, 160, 0, 1, 0, 0);

    // Concurrent directions use disjoint locations; B is the RAW ordering point.
    concurrent_started = $time;
    trace_concurrent = 1;
    if (verbose_concurrent) begin
      $display("MODEL_TRACE_START t=%0t", $time);
      $fflush();
    end
    fork
      // Keep each timed task in one fork branch. Verilator 5.008 otherwise
      // lowers the inlined task statements into separate parallel branches.
      begin : concurrent_write
        write_burst(BaseAddr + 'hb00, 4, FullSize, 1, 'h83);
      end
      begin : concurrent_read
        read_burst(BaseAddr, 8, FullSize, 1);
      end
    join
    trace_concurrent = 0;
    assert ($time > concurrent_started &&
            concurrent_aw == 1 && concurrent_w == 4 && concurrent_b == 1 &&
            concurrent_ar == 1 && concurrent_r == 8 &&
            concurrent_mem_writes == 4 && concurrent_mem_reads == 8)
      else $fatal(1, "STORAMIC_CONCURRENT_TRAFFIC aw=%0d w=%0d b=%0d ar=%0d r=%0d mw=%0d mr=%0d",
                  concurrent_aw, concurrent_w, concurrent_b, concurrent_ar, concurrent_r,
                  concurrent_mem_writes, concurrent_mem_reads);
    if (verbose_concurrent) begin
      $display("MODEL_TRACE_END t=%0t", $time);
      $fflush();
    end
    read_burst(BaseAddr + 'hb00, 4, FullSize, 1);

    grant_enable = 0;
    send_ar(BaseAddr, 1, FullSize, 1);
    while (!mem_req) tick();
    stalled_addr = mem_addr;
    stalled_data = mem_data;
    stalled_be = mem_be;
    stalled_tag = mem_tag;
    stalled_we = mem_we;
    repeat (5) begin
      tick();
      assert (mem_req && mem_addr == stalled_addr && mem_data == stalled_data &&
              mem_be == stalled_be && mem_tag == stalled_tag && mem_we == stalled_we)
        else $fatal(1, "STORAMIC_MEMORY_COMMAND_STABILITY");
    end
    grant_enable = 1;
    recv_read(BaseAddr, 1, FullSize, 1);

    // Equal sequence/source/ID/beat across resets isolate the generation check.
    reset_front();
    reply_enable = 0;
    send_ar(BaseAddr, 1, FullSize, 1);
    do @(posedge clk); while (!(mem_req && mem_gnt));
    stale_tag = mem_tag;
    tick();
    reset_front();
    send_ar(BaseAddr, 1, FullSize, 1);
    do @(posedge clk); while (!(mem_req && mem_gnt));
    new_tag = mem_tag;
    tick();
    assert (new_tag.seq == stale_tag.seq && new_tag.source == stale_tag.source &&
            new_tag.axi_id == stale_tag.axi_id && new_tag.beat == stale_tag.beat &&
            new_tag.reset_generation != stale_tag.reset_generation)
      else $fatal(1, "STORAMIC_GENERATION_FIXTURE");
    inject_stale = 1;
    tick();
    assert (faults[0] && !resp.r_valid && !resp.b_valid)
      else $fatal(1, "STORAMIC_STALE_COMPLETION_ACCEPTED");
    inject_stale = 0;
    reply_enable = 1;
    recv_read(BaseAddr, 1, FullSize, 1);

    // Abort an uncompleted write; this fixture commits only at completion.
    reply_enable = 0;
    send_aw(BaseAddr + 'hc00, 4, FullSize, 1);
    req.w = '{data: pattern('hff, 0), strb: {Bytes{1'b1}}, last: 1'b0, user: 1'b0};
    req.w_valid = 1;
    do @(posedge clk); while (!resp.w_ready);
    tick();
    req.w_valid = 0;
    do @(posedge clk); while (!(mem_req && mem_gnt));
    tick();
    reset_front();
    reply_enable = 1;
    read_burst(BaseAddr + 'hc00, 4, FullSize, 1);

    // Full byte-map comparison catches writes outside all requested lanes/spans.
    for (int offset = 0; offset < Capacity; offset += Bytes)
      read_burst(BaseAddr + 64'(offset), 1, FullSize, 1, 0, 0);
    assert (!resp.b_valid && !resp.r_valid && !mem_req)
      else $fatal(1, "STORAMIC_MODEL_EXTRA_RESPONSE");
    $display("STORAMIC_MODEL_PASS width=%0d id=%0d base=%h", DataWidth, IdWidth, BaseAddr);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "STORAMIC_MODEL_TIMEOUT commands=%0d ctrl_ar=%b/%b ctrl_r=%b/%b ar=%b/%b r=%b/%b aw=%b/%b w=%b/%b b=%b/%b mem=%b/%b/%b",
           commands, top_ctrl_req.ar_valid, top_ctrl_resp.ar_ready,
           top_ctrl_resp.r_valid, top_ctrl_req.r_ready,
           req.ar_valid, resp.ar_ready, resp.r_valid, req.r_ready,
           req.aw_valid, resp.aw_ready, req.w_valid, resp.w_ready,
           resp.b_valid, req.b_ready, mem_req, mem_gnt, model_rvalid);
  end
endmodule

// Production top with explicit model selection and external memory ports.
// No behavioral RAM enters this structural synthesis closure.
module g6lc_storamic_model_synth (
  input logic clk_i, rst_ni, testmode_i,
  input g6lc_storamic_pkg::axi_req_t req_i,
  output g6lc_storamic_pkg::axi_resp_t resp_o,
  input g6lc_storamic_pkg::axil_req_t ctrl_req_i,
  output g6lc_storamic_pkg::axil_resp_t ctrl_resp_o,
  input logic [7:0] source_i,
  input logic [31:0] reset_generation_i,
  output logic init_done_o, service_ready_o, model_ready_o, sequence_exhausted_o,
  output logic [2:0] faults_o,
  output g6lc_storamic_pkg::model_events_t events_o,
  output logic [0:0] media_ready_o,
  output g6lc_storamic_pad_pkg::pad_out_t [0:0] pad_o,
  input logic mem_ready_i,
  output logic mem_req_o,
  input logic mem_gnt_i,
  output logic mem_we_o,
  output logic [63:0] mem_addr_o, mem_wdata_o,
  output logic [7:0] mem_be_o,
  output g6lc_storamic_pkg::txn_id_t mem_tag_o,
  input logic mem_rvalid_i,
  input logic [63:0] mem_rdata_i,
  input logic mem_error_i,
  input g6lc_storamic_pkg::txn_id_t mem_tag_i
);
  g6lc_storamic_top #(.Cfg(g6lc_storamic_cfg_pkg::StoramicModel)) dut (.*);
endmodule
