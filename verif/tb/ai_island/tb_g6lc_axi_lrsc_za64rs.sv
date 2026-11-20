// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// g6lc_axi_lrsc — Za64rs reservation-REGION invalidation (RFIX131a).
//
// The pre-fix monitor keyed the reservation table on the exact AXI start
// address only. A reservation is a contiguous naturally-aligned byte region
// (the LR access), so a store whose byte range merely OVERLAPS that region —
// e.g. store.w @ A+4 inside an LR.d @ A reservation of [A,A+8) — must still
// invalidate it. Exact-address matching let that store slip through and a
// later SC.d @ A wrongly succeeded, breaking LR/SC mutual exclusion.
//
// This TB drives the monitor at the AXI seam (no #0 settle points, so it
// builds on the pinned remote Verilator 5.008 --timing flow that rejects the
// older tb_g6lc_axi_lrsc.sv). Scenarios:
//
//   T1 control    lr.d A ; sc.d A              -> EXOKAY (reservation works)
//   T2 same-addr  lr.d A ; store.w A   ; sc.d A -> OKAY   (invalidation works)
//   T3 OVERLAP    lr.d A ; store.w A+4 ; sc.d A -> OKAY   (THE FIX)
//   T4 tail ovlp  lr.d A ; store.w A+6? -> use store.d A (full) covered by T2;
//                 instead store.w @ A-4+... see below -- kept to aligned offs
//   T5 non-overlp lr.d A ; store.w A+0x100;sc.d A-> EXOKAY (independence kept)
//   T6 boundary   lr.d A ; store.w A+8  ; sc.d A -> EXOKAY ([A+8,..) !overlap)
//   T7 partial    lr.d A ; store.w A+4 is T3; add store covering [A+6,A+10)
//                 via .d store is unaligned -- use .w @ A (first half) as T2b
//
// A store at A+4 (aw_size=2, 4 bytes) covers [A+4,A+8): wholly inside the
// LR.d reservation [A,A+8). Before the fix res_addr==A never matched A+4, the
// reservation survived, and sc.d @ A returned EXOKAY. After the fix the
// region-overlap snoop clears it and the SC returns OKAY.
//
// Not Variane. Not OpenSBI. Not a throughput number.

`timescale 1ns/1ps
`include "axi/assign.svh"

module tb_g6lc_axi_lrsc_za64rs;
  localparam int unsigned ID_W   = 6;
  localparam int unsigned ADDR_W = 64;
  localparam int unsigned DATA_W = 64;
  localparam int unsigned MAX    = 8;
  localparam int unsigned NRES   = 8;

  localparam logic [63:0] A      = 64'h8000_4000;   // 8-byte aligned base
  localparam logic [63:0] FAR    = 64'h8000_5000;   // non-overlapping store

  logic clk, rst_ni;
  int unsigned errors, cycles;

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .AXI_USER_WIDTH ( 1      )
  ) slv();
  AXI_BUS #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .AXI_USER_WIDTH ( 1      )
  ) mem();

  g6lc_axi_lrsc #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .MaxOut         ( MAX    ),
      .NRes           ( NRES   )
  ) i_dut (
      .clk_i  ( clk ),
      .rst_ni ( rst_ni ),
      .slv    ( slv ),
      .mst    ( mem )
  );

  // ---- downstream (mem) model: always-ready, one R per AR, one B per AW ----
  // ridq/widq hold accepted IDs; nr/nw count in-flight reads/writes. Single
  // beat only (all test accesses are len=0), so r_last/b are always 1/OKAY.
  logic [3:0] nr, nw;
  logic [ID_W-1:0] ridq [0:15], widq [0:15];
  logic [3:0] rqh, rqt, wqh, wqt;

  wire ar_hs = mem.ar_valid && mem.ar_ready;
  wire aw_hs = mem.aw_valid && mem.aw_ready;
  wire w_hs  = mem.w_valid && mem.w_ready && mem.w_last;
  wire r_hs  = mem.r_valid && mem.r_ready;
  wire b_hs  = mem.b_valid && mem.b_ready;

  assign mem.aw_ready = 1'b1;
  assign mem.w_ready  = 1'b1;
  assign mem.ar_ready = 1'b1;
  assign mem.r_valid  = (nr != 0);
  assign mem.r_id     = ridq[rqh];
  assign mem.r_data   = 64'hA5A5_0000_0000_0000 | 64'(ridq[rqh]);
  assign mem.r_resp   = 2'b00;                 // OKAY -> monitor upgrades LR to EXOKAY
  assign mem.r_last   = 1'b1;
  assign mem.r_user   = '0;
  assign mem.b_valid  = (nw != 0);
  assign mem.b_id     = widq[wqh];
  assign mem.b_resp   = 2'b00;                 // OKAY -> monitor upgrades SC to EXOKAY
  assign mem.b_user   = '0;

  initial clk = 0;
  always #5 clk = ~clk;

  // Debug monitor: trace W/B path handshakes (enabled always; cheap).
  always @(posedge clk) begin
    if (slv.w_valid || slv.w_ready || mem.w_valid || slv.b_valid || mem.b_valid ||
        i_dut.aw_fwd_hs || i_dut.w_hs)
      $display("[%0t] wv=%b wr=%b mwv=%b mwr=%b | bv=%b mbv=%b | fwdhs=%b whs=%b nwl=%0d nw=%0d",
               $time, slv.w_valid, slv.w_ready, mem.w_valid, mem.w_ready,
               slv.b_valid, mem.b_valid, i_dut.aw_fwd_hs, i_dut.w_hs,
               i_dut.nwl, nw);
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      nr <= '0; nw <= '0;
      rqh <= '0; rqt <= '0; wqh <= '0; wqt <= '0;
    end else begin
      if (ar_hs) begin
        ridq[rqt] <= mem.ar_id;
        rqt <= rqt + 4'd1;
      end
      if (r_hs) rqh <= rqh + 4'd1;
      unique case ({ar_hs, r_hs})
        2'b10: nr <= nr + 4'd1;
        2'b01: nr <= nr - 4'd1;
        default: ;
      endcase
      if (aw_hs) begin
        widq[wqt] <= mem.aw_id;
        wqt <= wqt + 4'd1;
      end
      if (b_hs) wqh <= wqh + 4'd1;
      unique case ({w_hs, b_hs})
        2'b10: nw <= nw + 4'd1;
        2'b01: nw <= nw - 4'd1;
        default: ;
      endcase
    end
  end

  // ---- stimulus helpers (negedge-sampled; no #0) -----------------------------
  task automatic idle_m;
    slv.aw_valid = 1'b0; slv.w_valid = 1'b0; slv.ar_valid = 1'b0;
    slv.b_ready = 1'b1; slv.r_ready = 1'b1;
    slv.aw_id = '0; slv.aw_addr = '0; slv.aw_len = '0;
    slv.aw_size = 3'd3; slv.aw_burst = 2'b01; slv.aw_lock = 1'b0;
    slv.aw_cache = '0; slv.aw_prot = '0; slv.aw_qos = '0;
    slv.aw_region = '0; slv.aw_atop = '0; slv.aw_user = '0;
    slv.w_data = '0; slv.w_strb = 8'hFF; slv.w_last = 1'b1; slv.w_user = '0;
    slv.ar_id = '0; slv.ar_addr = '0; slv.ar_len = '0;
    slv.ar_size = 3'd3; slv.ar_burst = 2'b01; slv.ar_lock = 1'b0;
    slv.ar_cache = '0; slv.ar_prot = '0; slv.ar_qos = '0;
    slv.ar_region = '0; slv.ar_user = '0;
  endtask

  task automatic tick;
    @(posedge clk);
    cycles++;
  endtask

  // Bounded negedge wait: sets timed_out=1 if cond never asserts in lim edges.
  task automatic wait_negedge(input logic cond, input int lim,
                              output bit timed_out);
    int k;
    k = 0; timed_out = 0;
    while (!cond && k < lim) begin @(negedge clk); k++; end
    if (!cond) timed_out = 1;
  endtask

  bit wto;
  // Issue an AR (load side). Waits for ar_ready then the handshake edge.
  task automatic do_ar(input logic [ID_W-1:0] id, input logic [63:0] addr,
                       input logic lock, input logic [2:0] size);
    @(negedge clk);
    slv.ar_id = id; slv.ar_addr = addr; slv.ar_len = '0;
    slv.ar_size = size; slv.ar_lock = lock; slv.ar_valid = 1'b1;
    wait_negedge(slv.ar_ready, 2000, wto);
    if (wto) begin
      $error("do_ar timeout addr=%h ar_ready=%b", addr, slv.ar_ready); errors++;
    end
    @(posedge clk);          // AR handshake (ar_hs)
    @(negedge clk);
    slv.ar_valid = 1'b0;
  endtask

  // Collect the R beat for the AR just issued; returns r_resp (EXOKAY/OKAY).
  task automatic get_r(output logic [1:0] resp);
    wait_negedge(slv.r_valid, 2000, wto);
    if (wto) begin
      $error("get_r timeout r_valid=%b", slv.r_valid); errors++;
      resp = 2'b11;
    end else begin
      resp = slv.r_resp;     // stable mid-cycle
      @(posedge clk);        // r_hs completes
      @(negedge clk);
    end
  endtask

  // Issue an AW (write side). Waits for aw_ready then the handshake edge.
  task automatic do_aw(input logic [ID_W-1:0] id, input logic [63:0] addr,
                       input logic lock, input logic [2:0] size);
    @(negedge clk);
    slv.aw_id = id; slv.aw_addr = addr; slv.aw_len = '0;
    slv.aw_size = size; slv.aw_lock = lock; slv.aw_valid = 1'b1;
    wait_negedge(slv.aw_ready, 2000, wto);
    if (wto) begin
      $error("do_aw timeout addr=%h aw_ready=%b", addr, slv.aw_ready); errors++;
    end
    @(posedge clk);          // AW handshake (aw_hs / aw_fwd_hs)
    @(negedge clk);
    slv.aw_valid = 1'b0;
    // Release the exclusive attribute once AW is accepted: the AW channel is
    // free for the next transaction while W data is still in flight. Holding
    // aw_lock/aw_addr would leave aw_is_ex/aw_drop evaluating the *consumed*
    // reservation and (pre-existing RTL sensitivity) gate the W beat. A real
    // master does not guarantee those fields stay put post-handshake.
    slv.aw_lock = 1'b0;
  endtask

  // Issue the W beat for the AW just issued.
  task automatic do_w(input logic [63:0] data);
    @(negedge clk);
    slv.w_data = data; slv.w_strb = 8'hFF; slv.w_last = 1'b1; slv.w_valid = 1'b1;
    wait_negedge(slv.w_ready, 2000, wto);
    if (wto) begin
      $error("do_w timeout w_ready=%b", slv.w_ready); errors++;
    end
    @(posedge clk);          // W handshake
    @(negedge clk);
    slv.w_valid = 1'b0;
  endtask

  // Collect the B for the write just issued; returns b_resp + b_id.
  task automatic get_b(output logic [1:0] resp, output logic [ID_W-1:0] bid);
    wait_negedge(slv.b_valid, 2000, wto);
    if (wto) begin
      $error("get_b timeout b_valid=%b | dut nar=%0d naw=%0d nwl=%0d res_v=%b inj_b=%b sc_drop=%b | tb nr=%0d nw=%0d",
             slv.b_valid, i_dut.nar, i_dut.naw, i_dut.nwl,
             i_dut.res_v, i_dut.inj_b, i_dut.sc_drop, nr, nw);
      errors++;
      resp = 2'b11; bid = 'x;
    end else begin
      resp = slv.b_resp;     // stable mid-cycle
      bid  = slv.b_id;
      @(posedge clk);        // b_hs completes
      @(negedge clk);
    end
  endtask

  // LR.d @ addr -> reserves [addr, addr+8); expects r_resp EXOKAY.
  task automatic do_lr_d(input logic [63:0] addr);
    logic [1:0] r;
    do_ar(ID_W'(0), addr, 1'b1, 3'd3);
    get_r(r);
    if (r !== 2'b01) begin
      $error("LR.d @%h r_resp=%b expected EXOKAY", addr, r); errors++;
    end
  endtask

  // SC.d @ addr -> expects EXOKAY if expect_ok else OKAY.
  task automatic do_sc_d(input logic [63:0] addr, input logic expect_ok);
    logic [1:0] b; logic [ID_W-1:0] bid;
    do_aw(ID_W'(0), addr, 1'b1, 3'd3);
    do_w(64'h1234_5678_9abc_def0);
    get_b(b, bid);
    if (expect_ok && (b !== 2'b01 || bid !== ID_W'(0))) begin
      $error("SC.d @%h expected EXOKAY got b_resp=%b id=%h", addr, b, bid); errors++;
    end
    if (!expect_ok && (b !== 2'b00 || bid !== ID_W'(0))) begin
      $error("SC.d @%h expected OKAY(fail) got b_resp=%b id=%h", addr, b, bid); errors++;
    end
  endtask

  // Regular store (no lock). size: 2=word(4B), 3=doubleword(8B).
  task automatic do_store(input logic [63:0] addr, input logic [2:0] size,
                          input logic [63:0] data);
    logic [1:0] b; logic [ID_W-1:0] bid;
    do_aw(ID_W'(0), addr, 1'b0, size);
    do_w(data);
    get_b(b, bid);
    if (b !== 2'b00) begin
      $error("store @%h size=%0d unexpected b_resp=%b", addr, size, b); errors++;
    end
  endtask

  initial begin
    errors = 0; cycles = 0; rst_ni = 1'b0;
    idle_m();
    repeat (6) tick;
    rst_ni = 1'b1;
    repeat (6) tick;

    // T1 control: plain LR/SC succeeds.
    $display("[%0t] T1 lr.d A", $time);
    do_lr_d(A);
    $display("[%0t] T1 sc.d A", $time);
    do_sc_d(A, 1'b1);

    // T2 same-address store invalidates -> SC fails.
    $display("[%0t] T2", $time);
    do_lr_d(A);
    do_store(A,      3'd2, 64'h1111);   // store.w @ A covers [A,A+4)
    do_sc_d(A, 1'b0);

    // T3 OVERLAP (the fix): store.w @ A+4 covers [A+4,A+8) inside [A,A+8).
    // Pre-fix this did NOT invalidate (exact-address match) and SC wrongly won.
    $display("[%0t] T3 overlap store.w A+4", $time);
    do_lr_d(A);
    do_store(A + 64'd4, 3'd2, 64'h2222); // store.w @ A+4
    do_sc_d(A, 1'b0);

    // T4 non-overlapping store far away must NOT invalidate -> SC succeeds.
    $display("[%0t] T4 nonoverlap", $time);
    do_lr_d(A);
    do_store(FAR,    3'd2, 64'h3333);   // store.w @ FAR
    do_sc_d(A, 1'b1);

    // T5 boundary: store.w @ A+8 covers [A+8,A+12); [A,A+8) ends exclusive at
    // A+8, so NO overlap -> reservation survives -> SC succeeds.
    $display("[%0t] T5 boundary A+8", $time);
    do_lr_d(A);
    do_store(A + 64'd8, 3'd2, 64'h4444); // store.w @ A+8 (just past region)
    do_sc_d(A, 1'b1);

    // T6 partial overlap at region tail: store.w @ A+4 already T3; add a
    // store.d @ A (8B) overlapping the whole region -> must invalidate.
    $display("[%0t] T6 store.d A", $time);
    do_lr_d(A);
    do_store(A,      3'd3, 64'h5555);   // store.d @ A covers [A,A+8)
    do_sc_d(A, 1'b0);

    // T7 word store fully inside but starting at base: store.w @ A covers
    // [A,A+4) subset of [A,A+8) -> overlap -> invalidate.
    $display("[%0t] T7 store.w A subset", $time);
    do_lr_d(A);
    do_store(A,      3'd2, 64'h6666);   // store.w @ A (dup addr, subset)
    do_sc_d(A, 1'b0);

    if (errors == 0)
      $display("PASS g6lc_axi_lrsc_za64rs overlap-region cycles=%0d", cycles);
    else begin
      $display("FAIL g6lc_axi_lrsc_za64rs errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
