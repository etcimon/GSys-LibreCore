// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

// ST-035 split-ring engine bench. An independent byte-addressed memory model
// serves the DMA port with random grant and response latency, checks every
// beat against the DMA window and records every written byte. The bench builds
// split rings the way a driver does and models the backend. Expected used
// entries are computed from what the bench placed in memory, never from the DUT.
module tb_g6lc_storamic_virtio_ring;
  localparam int unsigned MaxSegs = 4;
  localparam logic [63:0] WinBase = 64'h8000_0000;
  localparam logic [63:0] WinSize = 64'h0010_0000;

  logic clk = 1'b0, rst_n = 1'b0;
  always #5 clk = ~clk;
  task automatic tick; @(negedge clk); endtask

  // ---- transport-side stimulus ----
  logic qready = 0, dok = 0, notify = 0, rpend = 0;
  logic [15:0] qnum = 16'd8;
  logic [63:0] qdesc, qdrv, qdev;
  logic [7:0] epoch = '0;
  logic idle, used_ev, fault;

  // ---- DMA port ----
  logic dreq, dgnt = 0, dwe, drv = 0, derr = 0;
  logic [63:0] daddr, dwdata, drdata = '0;
  logic [7:0] dbe;

  // ---- backend port ----
  logic bvalid, bready = 0, brsp = 0, bfault = 0;
  logic [15:0] bhead;
  logic [$clog2(MaxSegs + 1)-1:0] bnsegs;
  logic [MaxSegs-1:0][63:0] bsaddr;
  logic [MaxSegs-1:0][31:0] bslen;
  logic [MaxSegs-1:0] bswr;
  logic [31:0] bwlen = '0;

  g6lc_storamic_virtio_ring #(.MaxSegs(MaxSegs), .QueueNumMax(128)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .queue_ready_i(qready), .queue_num_i(qnum), .queue_desc_i(qdesc),
    .queue_driver_i(qdrv), .queue_device_i(qdev), .driver_ok_i(dok),
    .notify_i(notify), .reset_pending_i(rpend), .reset_epoch_i(epoch),
    .dma_idle_o(idle), .used_event_o(used_ev), .ring_fault_o(fault),
    .dma_base_i(WinBase), .dma_size_i(WinSize),
    .dma_req_o(dreq), .dma_gnt_i(dgnt), .dma_we_o(dwe), .dma_addr_o(daddr),
    .dma_wdata_o(dwdata), .dma_be_o(dbe), .dma_rvalid_i(drv),
    .dma_rdata_i(drdata), .dma_err_i(derr),
    .req_valid_o(bvalid), .req_ready_i(bready), .req_head_o(bhead),
    .req_nsegs_o(bnsegs), .req_seg_addr_o(bsaddr), .req_seg_len_o(bslen),
    .req_seg_write_o(bswr), .rsp_valid_i(brsp),
    .rsp_written_len_i(bwlen), .rsp_fault_i(bfault)
  );

  // ---- memory model ----
  logic [7:0] mem [logic [63:0]];
  bit written [logic [63:0]];
  int beats = 0, win_viol = 0, outstanding = 0, multi_out = 0;
  int unsigned seed = 1;
  int gnt_pct = 60, lat_max = 3;

  function automatic logic [63:0] rd64(input logic [63:0] a);
    logic [63:0] v;
    for (int i = 0; i < 8; i++)
      v[8*i +: 8] = mem.exists(a + i) ? mem[a + i] : 8'h00;
    return v;
  endfunction
  task automatic wr8(input logic [63:0] a, input logic [7:0] v); mem[a] = v; endtask
  task automatic wr16(input logic [63:0] a, input logic [15:0] v);
    wr8(a, v[7:0]); wr8(a + 1, v[15:8]);
  endtask
  task automatic wr32(input logic [63:0] a, input logic [31:0] v);
    wr16(a, v[15:0]); wr16(a + 2, v[31:16]);
  endtask
  task automatic wr64(input logic [63:0] a, input logic [63:0] v);
    wr32(a, v[31:0]); wr32(a + 4, v[63:32]);
  endtask
  function automatic logic [15:0] get16(input logic [63:0] a);
    return {mem.exists(a + 1) ? mem[a + 1] : 8'h0, mem.exists(a) ? mem[a] : 8'h0};
  endfunction
  function automatic logic [31:0] get32(input logic [63:0] a);
    return {get16(a + 2), get16(a)};
  endfunction

  // One outstanding beat: grant randomly, answer after a random latency.
  int lat;
  logic busy = 0, bwe;
  logic [63:0] baddr, bwdata;
  logic [7:0] bbe;
  int stall_rvalid = 0;   // extra latency for the reset-during-walk case
  always @(negedge clk) begin
    dgnt <= ($urandom % 100) < gnt_pct;
    if (busy && !drv) begin
      if (lat > 0) lat <= lat - 1;
      else begin
        drv <= 1'b1;
        drdata <= bwe ? 64'h0 : rd64(baddr);
      end
    end
  end
  always @(posedge clk) begin
    if (rst_n && dreq && dgnt && !busy) begin
      busy <= 1'b1; bwe <= dwe; baddr <= daddr; bwdata <= dwdata; bbe <= dbe;
      lat <= ($urandom % (lat_max + 1)) + stall_rvalid;
      beats++;
      if (daddr[2:0] != 0 || daddr < WinBase || daddr + 8 > WinBase + WinSize)
        win_viol++;
      if (dwe)
        for (int i = 0; i < 8; i++)
          if (dbe[i]) begin
            mem[daddr + i] = dwdata[8*i +: 8];
            written[daddr + i] = 1'b1;
          end
    end
    if (rst_n && dreq && dgnt && busy) multi_out++;
    if (drv) begin
      drv <= 1'b0; busy <= 1'b0;
    end
  end

  // ---- backend model ----
  int be_delay = 2;
  bit be_hold = 0;          // keep the response back (stale-response case)
  int be_reqs = 0;
  logic [15:0] be_head;
  int be_nsegs;
  logic [31:0] be_wlen;
  always @(negedge clk) begin
    bready <= ($urandom % 100) < 70;
  end
  initial begin
    forever begin
      @(posedge clk);
      if (bvalid && bready) begin
        be_reqs++;
        be_head = bhead; be_nsegs = int'(bnsegs);
        be_wlen = 0;
        for (int i = 0; i < MaxSegs; i++)
          if (i < be_nsegs && bswr[i]) be_wlen += bslen[i];
        repeat (be_delay) @(negedge clk);
        while (be_hold) @(negedge clk);
        @(negedge clk);
        bwlen = be_wlen; brsp = 1'b1;
        @(negedge clk);
        brsp = 1'b0;
      end
    end
  end

  int used_events = 0, faults = 0;
  always @(posedge clk) begin
    if (used_ev) used_events++;
    if (fault) faults++;
  end

  int checks = 0;
  bit corrupt = 0;
  task automatic ok(input bit c, input string n);
    checks++;
    if (!c) $fatal(1, "VRING_FAIL %s", n);
  endtask
  task automatic section(input string n);
    $display("VRING_SECTION %s", n);
    $fflush();
  endtask
  // Counters are read directly each cycle: a ref argument is not refreshed
  // across timing controls by the pinned simulator.
  function automatic int cnt(input int which);
    case (which)
      0: return used_events;
      1: return be_reqs;
      2: return faults;
      default: return beats;
    endcase
  endfunction
  task automatic wait_cond(input string n, input int which, input int target);
    int g;
    g = 0;
    while (cnt(which) < target) begin
      tick(); g++;
      if (g > 4000)
        $fatal(1, "VRING_TIMEOUT %s state=%0d beats=%0d faults=%0d be_reqs=%0d busy=%0d dreq=%0d np=%0d",
               n, dut.state_q, beats, faults, be_reqs, busy, dreq, dut.notify_pend_q);
    end
  endtask
  task automatic settle(input int n); repeat (n) tick(); endtask
  task automatic pulse_notify; notify = 1; tick(); notify = 0; endtask

  // Driver-side ring helpers.
  logic [15:0] drv_avail;
  task automatic ring_init(input logic [63:0] d, input logic [63:0] a,
                           input logic [63:0] u, input logic [15:0] n);
    qdesc = d; qdrv = a; qdev = u; qnum = n;
    for (int i = 0; i < 16 * n + 16; i++) mem[d + i] = 8'h0;
    for (int i = 0; i < 6 + 2 * n; i++) mem[a + i] = 8'h0;
    for (int i = 0; i < 6 + 8 * n; i++) mem[u + i] = 8'h0;
    written.delete();
    drv_avail = 0;
  endtask
  task automatic set_desc(input int i, input logic [63:0] addr, input logic [31:0] len,
                          input logic [15:0] flags, input logic [15:0] next);
    wr64(qdesc + 16 * i, addr);
    wr32(qdesc + 16 * i + 8, len);
    wr16(qdesc + 16 * i + 12, flags);
    wr16(qdesc + 16 * i + 14, next);
  endtask
  task automatic post(input logic [15:0] head);
    wr16(qdrv + 4 + 2 * (drv_avail % qnum), head);
    drv_avail++;
    wr16(qdrv + 2, drv_avail);
  endtask
  // Standard blk-like chain at descriptor base index b: hdr(R,16) data(W,512) st(W,1).
  task automatic chain3(input int b);
    set_desc(b, 64'h8000_8000 + 64'(b) * 64'h400, 16, 16'h1, 16'(b + 1));
    set_desc(b + 1, 64'h8000_9000 + 64'(b) * 64'h400, 512, 16'h3, 16'(b + 2));
    set_desc(b + 2, 64'h8000_7000 + 64'(b), 1, 16'h2, 16'h0);
  endtask
  task automatic device_reset;
    rpend = 1;
    begin
      int g; g = 0;
      do begin tick(); g++; if (g > 400) $fatal(1, "VRING_TIMEOUT reset"); end
      while (!idle);
    end
    epoch = epoch + 1;
    tick();
    rpend = 0;
    tick();
  endtask
  // Count of written bytes outside [lo, hi).
  function automatic int writes_outside(input logic [63:0] lo, input logic [63:0] hi);
    int n;
    n = 0;
    foreach (written[a]) if (a < lo || a >= hi) n++;
    return n;
  endfunction

  initial begin
    if ($test$plusargs("oracle_negative")) corrupt = 1;
    repeat (3) tick(); rst_n = 1; repeat (2) tick();

    section("no-dma-before-ready");
    ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3004, 8);
    chain3(0); post(0);
    pulse_notify(); settle(20);
    ok(beats == 0, "no-dma-without-dok");
    dok = 1; pulse_notify(); settle(20);
    ok(beats == 0, "no-dma-without-qready");

    section("single");
    qready = 1;
    begin
      int ue0;
      ue0 = used_events;
      // The earlier notifies were remembered; one more makes it explicit.
      pulse_notify();
      wait_cond("single", 0, ue0 + 1);
      settle(10);
      ok(be_head == 0 && be_nsegs == 3, "single-backend-req");
      ok(get32(qdev + 4) == 32'd0, "single-used-id");
      ok(get32(qdev + 8) == (corrupt ? 32'd512 : 32'd513), "single-used-len");
      ok(get16(qdev + 2) == 16'd1, "single-used-idx");
      ok(writes_outside(qdev + 2, qdev + 12) == 0, "single-no-stray-writes");
      ok(used_events == ue0 + 1, "single-one-event");
    end

    section("burst-aligned-used");
    device_reset();
    ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3000, 8);
    for (int r = 0; r < 2; r++) chain3(3 * r);
    set_desc(6, 64'h8000_6000, 16, 16'h1, 16'd7);
    set_desc(7, 64'h8000_6100, 1, 16'h2, 16'd0);
    post(0); post(3); post(6); post(0); post(3);
    begin
      int ue0;
      ue0 = used_events;
      pulse_notify();
      wait_cond("burst", 0, ue0 + 5);
      settle(10);
      ok(get16(qdev + 2) == 16'd5, "burst-used-idx");
      ok(get32(qdev + 4 + 8 * 2) == 32'd6 && get32(qdev + 8 + 8 * 2) == 32'd1,
         "burst-entry2");
      ok(get32(qdev + 4 + 8 * 4) == 32'd3 && get32(qdev + 8 + 8 * 4) == 32'd513,
         "burst-entry4");
      ok(writes_outside(qdev + 2, qdev + 4 + 8 * 8) == 0, "burst-no-stray");
    end

    section("wrap-n4");
    device_reset();
    ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3004, 4);
    set_desc(0, 64'h8000_6000, 16, 16'h1, 16'd1);
    set_desc(1, 64'h8000_6100, 8, 16'h2, 16'd0);
    begin
      int ue0;
      ue0 = used_events;
      for (int r = 0; r < 11; r++) begin
        post(0);
        pulse_notify();
        wait_cond("wrap", 0, ue0 + r + 1);
      end
      settle(5);
      ok(get16(qdev + 2) == 16'd11, "wrap-used-idx");
      ok(get32(qdev + 4 + 8 * (10 % 4)) == 32'd0 &&
         get32(qdev + 8 + 8 * (10 % 4)) == 32'd8, "wrap-slot");
    end

    section("notify-while-busy");
    device_reset();
    ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3000, 8);
    chain3(0); chain3(3);
    be_delay = 20;
    begin
      int ue0, r0;
      ue0 = used_events; r0 = be_reqs;
      post(0); pulse_notify();
      wait_cond("nwb-req", 1, r0 + 1);
      post(3); pulse_notify();
      wait_cond("nwb", 0, ue0 + 2);
      ok(get16(qdev + 2) == 16'd2, "nwb-both");
    end
    be_delay = 2;

    section("faults");
    for (int k = 0; k < 8; k++) begin
      int b0, f0, ue0;
      device_reset();
      ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3000, 8);
      unique case (k)
        0: begin // cycle 0 -> 1 -> 0
          set_desc(0, 64'h8000_6000, 16, 16'h1, 16'd1);
          set_desc(1, 64'h8000_6100, 16, 16'h1, 16'd0);
        end
        1: set_desc(0, 64'h8000_6000, 16, 16'h1, 16'd9);           // next >= N
        2: set_desc(0, 64'h8000_6000, 16, 16'h4, 16'd0);           // INDIRECT
        3: begin                                                     // R after W
          set_desc(0, 64'h8000_6000, 16, 16'h3, 16'd1);
          set_desc(1, 64'h8000_6100, 16, 16'h0, 16'd0);
        end
        4: set_desc(0, 64'h8000_6000, 0, 16'h0, 16'd0);            // len 0
        5: set_desc(0, 64'h8010_0000 - 8, 16, 16'h0, 16'd0);       // seg past window
        6: begin                                                     // > MaxSegs
          for (int i = 0; i < 5; i++)
            set_desc(i, 64'h8000_6000 + 64'(i) * 64'h100, 16, 16'h1, 16'(i + 1));
          set_desc(5, 64'h8000_6600, 1, 16'h2, 16'd0);
        end
        7: begin                                                     // ring outside
          qdesc = 64'h8010_0000;
        end
      endcase
      post(0);
      b0 = beats; f0 = faults; ue0 = used_events;
      pulse_notify();
      wait_cond($sformatf("fault-%0d", k), 2, f0 + 1);
      begin
        int b1;
        b1 = beats;
        settle(30);
        ok(beats == b1, $sformatf("fault-%0d-no-dma-after", k));
      end
      ok(used_events == ue0 && writes_outside(0, 0) == 0,
         $sformatf("fault-%0d-no-used-write", k));
      ok(faults == f0 + 1, $sformatf("fault-%0d-one-pulse", k));
    end

    section("backend-fault");
    device_reset();
    ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3000, 8);
    chain3(0); post(0);
    bfault = 1;
    begin
      int f0;
      f0 = faults;
      pulse_notify();
      wait_cond("bfault", 2, f0 + 1);
      settle(10);
      ok(writes_outside(0, 0) == 0, "bfault-no-used-write");
    end
    bfault = 0;

    section("reset-during-walk");
    device_reset();
    ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3000, 8);
    chain3(0); post(0);
    stall_rvalid = 20;
    begin
      int b0, g;
      b0 = beats;
      pulse_notify();
      wait_cond("rdw-beat", 3, b0 + 1);
      rpend = 1;
      tick();
      ok(!idle && busy, "rdw-not-idle-while-outstanding");
      g = 0;
      while (!idle) begin tick(); g++; if (g > 200) $fatal(1, "VRING_TIMEOUT rdw"); end
      ok(!busy, "rdw-idle-after-response");
      b0 = beats;
      settle(20);
      ok(beats == b0 && !dreq, "rdw-no-dma-while-pending");
      epoch = epoch + 1; tick(); rpend = 0; tick();
    end
    stall_rvalid = 0;
    ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3000, 8);
    chain3(0); post(0);
    begin
      int ue0;
      ue0 = used_events;
      pulse_notify();
      wait_cond("rdw-after", 0, ue0 + 1);
      settle(5);
      ok(get16(qdev + 2) == 16'd1, "rdw-indices-restart");
    end

    section("stale-backend-response");
    device_reset();
    ring_init(64'h8000_1000, 64'h8000_2000, 64'h8000_3000, 8);
    chain3(0); post(0);
    be_hold = 1;
    begin
      int r0;
      r0 = be_reqs;
      pulse_notify();
      wait_cond("stale-req", 1, r0 + 1);
      rpend = 1; settle(5);
      be_hold = 0; settle(10);      // the backend answers while reset is pending
      epoch = epoch + 1; tick(); rpend = 0; settle(10);
      ok(writes_outside(0, 0) == 0, "stale-no-used-write");
    end

    ok(win_viol == 0, "no-window-violations");
    ok(multi_out == 0, "one-outstanding");
    $display("VRING_PASS checks=%0d beats=%0d", checks, beats);
    $finish;
  end

  initial begin
    #2000000;
    $fatal(1, "VRING_TIMEOUT global");
  end
endmodule

// Synthesis wrapper (top level).
module g6lc_storamic_virtio_ring_synth (
  input logic clk_i,
  input logic rst_ni,
  input logic queue_ready_i,
  input logic [15:0] queue_num_i,
  input logic [63:0] queue_desc_i,
  input logic [63:0] queue_driver_i,
  input logic [63:0] queue_device_i,
  input logic driver_ok_i,
  input logic notify_i,
  input logic reset_pending_i,
  input logic [7:0] reset_epoch_i,
  output logic dma_idle_o,
  output logic used_event_o,
  output logic ring_fault_o,
  input logic [63:0] dma_base_i,
  input logic [63:0] dma_size_i,
  output logic dma_req_o,
  input logic dma_gnt_i,
  output logic dma_we_o,
  output logic [63:0] dma_addr_o,
  output logic [63:0] dma_wdata_o,
  output logic [7:0] dma_be_o,
  input logic dma_rvalid_i,
  input logic [63:0] dma_rdata_i,
  input logic dma_err_i,
  output logic req_valid_o,
  input logic req_ready_i,
  output logic [15:0] req_head_o,
  output logic [3:0] req_nsegs_o,
  output logic [7:0][63:0] req_seg_addr_o,
  output logic [7:0][31:0] req_seg_len_o,
  output logic [7:0] req_seg_write_o,
  input logic rsp_valid_i,
  input logic [31:0] rsp_written_len_i,
  input logic rsp_fault_i
);
  g6lc_storamic_virtio_ring #(.MaxSegs(8), .QueueNumMax(128)) i_ring (.*);
endmodule
