// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// g6lc_axi_lrsc: eight regular AR/AW live, 9th backpressure; LR/SC snoop.
// Not Variane. Not 400 GB/s.

`timescale 1ns/1ps
`include "axi/assign.svh"

module tb_g6lc_axi_lrsc;
  localparam int unsigned ID_W   = 6;
  localparam int unsigned ADDR_W = 64;
  localparam int unsigned DATA_W = 64;
  localparam int unsigned MAX    = 8;
  // Reservation-table depth. `+define+G6LC_TB_LRSC_SINGLE_RES` builds the
  // pre-fix behaviour (one global reservation) so the disjoint scenario below
  // can be shown to FAIL on it. A test that has never failed is not an oracle,
  // so this negative control is a permanent part of the TB rather than a
  // throwaway local edit.
`ifdef G6LC_TB_LRSC_SINGLE_RES
  localparam int unsigned NRES   = 1;
`else
  localparam int unsigned NRES   = 8;
`endif

  logic clk, rst_ni, r_go, b_go;
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

`ifdef G6LC_TB_ATOMICS_WRAP
  g6lc_axi_atomics_wrap #(
      .AXI_ADDR_WIDTH     ( ADDR_W ),
      .AXI_DATA_WIDTH     ( DATA_W ),
      .AXI_ID_WIDTH       ( ID_W   ),
      .AXI_MAX_WRITE_TXNS ( MAX    ),
      .RISCV_WORD_WIDTH   ( 64     ),
      .NRes               ( NRES   )
  ) i_dut (
      .clk_i  ( clk ),
      .rst_ni ( rst_ni ),
      .slv    ( slv ),
      .mst    ( mem )
  );
`else
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
`endif

  logic [3:0] nr, nw;
  logic [ID_W-1:0] ridq [0:15], widq [0:15];
  logic [3:0] rqh, rqt, wqh, wqt;
  int unsigned nstore;

  wire ar_hs = mem.ar_valid && mem.ar_ready;
  wire aw_hs = mem.aw_valid && mem.aw_ready;
  wire w_hs  = mem.w_valid && mem.w_ready && mem.w_last;
  wire r_hs  = mem.r_valid && mem.r_ready;
  wire b_hs  = mem.b_valid && mem.b_ready;

  assign mem.aw_ready = 1'b1;
  assign mem.w_ready  = 1'b1;
  assign mem.ar_ready = 1'b1;
  assign mem.r_valid  = r_go && (nr != 0);
  assign mem.r_id     = ridq[rqh];
  assign mem.r_data   = 64'hA5A5_0000_0000_0000 | 64'(ridq[rqh]);
  assign mem.r_resp   = 2'b00;
  assign mem.r_last   = 1'b1;
  assign mem.r_user   = '0;
  assign mem.b_valid  = b_go && (nw != 0);
  assign mem.b_id     = widq[wqh];
  assign mem.b_resp   = 2'b00;
  assign mem.b_user   = '0;

  initial clk = 0;
  always #5 clk = ~clk;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      nr <= '0; nw <= '0;
      rqh <= '0; rqt <= '0; wqh <= '0; wqt <= '0;
      nstore <= 0;
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
        nstore <= nstore + 1;
      end
      if (b_hs) wqh <= wqh + 4'd1;
      unique case ({w_hs, b_hs})
        2'b10: nw <= nw + 4'd1;
        2'b01: nw <= nw - 4'd1;
        default: ;
      endcase
    end
  end

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

  // ---------------------------------------------------------------------------
  // This testbench cannot be built by the pinned remote Verilator 5.008.
  // ---------------------------------------------------------------------------
  // The `#0;` settle points below are rejected outright:
  //   %Error-ZERODLY: #0 delays do not schedule process resumption in the
  //                   Inactive region
  // 15 sites here, 5 in tb_g6lc_ai_atomics_aw.sv, 19 in
  // tb_g6lc_ai_litedram_wrap.sv -- so the whole unit-TB family is unavailable
  // on the proxy, and the cycle counts recorded for `ai-dram-atomics` came
  // from some other tool and are not reproducible there.
  //
  // Two cheap substitutions were tried and BOTH FAIL, identically:
  //
  //   #0;  ->  #1;                 hs_ar "timeout AR" at t=4145000
  //   #0;  ->  @(negedge clk);     hs_ar "timeout AR" at t=4145000
  //
  // Same timestamp for both, deep in the sequence rather than at the first
  // handshake, and after the 8-deep AR-backpressure scenario. So the settle
  // point is not the discriminator: something in the R/B drain accounting
  // (`got`, `nr`/`nw`, the `r_go`/`b_go` gating of mem.r_valid/mem.b_valid)
  // depends on resuming *pre*-NBA, and `nar` never falls back below MaxOut,
  // which starves the next hs_ar. Recorded so the next attempt does not
  // re-derive it: this needs the drain loops restructured around a defined
  // sampling point, not a delay swapped out.
  //
  // Until then the citable exclusive-monitor evidence is harness-level
  // (ai-dual-core-excl, ai-dual-core-lrsc-disjoint on Variane), and
  // run-lrsc-oracle.sh reports SKIP rather than pretending to a verdict.

  task automatic hs_ar(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!slv.ar_ready && cycles < tlim) tick;
    if (!slv.ar_ready) begin $error("timeout AR"); errors++; end
    else tick;
    slv.ar_valid = 1'b0; slv.ar_lock = 1'b0;
  endtask

  task automatic hs_aw(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!slv.aw_ready && cycles < tlim) tick;
    if (!slv.aw_ready) begin $error("timeout AW"); errors++; end
    else tick;
    slv.aw_valid = 1'b0; slv.aw_lock = 1'b0;
  endtask

  task automatic hs_w(input int unsigned lim);
    int unsigned tlim;
    tlim = cycles + lim;
    #0;
    while (!slv.w_ready && cycles < tlim) tick;
    if (!slv.w_ready) begin $error("timeout W"); errors++; end
    else tick;
    slv.w_valid = 1'b0;
  endtask

  task automatic issue_ar(input logic [ID_W-1:0] id, input logic [63:0] addr, input logic lock);
    slv.ar_id = id; slv.ar_addr = addr; slv.ar_len = '0;
    slv.ar_lock = lock; slv.ar_valid = 1'b1;
    hs_ar(400);
  endtask

  task automatic issue_aw_w(
      input logic [ID_W-1:0] id, input logic [63:0] addr,
      input logic [63:0] data, input logic lock
  );
    slv.aw_id = id; slv.aw_addr = addr; slv.aw_len = '0;
    slv.aw_lock = lock; slv.aw_valid = 1'b1;
    hs_aw(400);
    slv.w_data = data; slv.w_strb = 8'hFF; slv.w_last = 1'b1; slv.w_valid = 1'b1;
    hs_w(400);
  endtask

  initial begin
    errors = 0; cycles = 0; rst_ni = 1'b0; r_go = 1'b0; b_go = 1'b0;
    idle_m();
    repeat (4) tick;
    rst_ni = 1'b1;
    repeat (4) tick;

    // Eight regular AR, 9th backpressure.
    slv.r_ready = 1'b0;
    begin
      int unsigned s;
      for (s = 0; s < MAX; s++)
        issue_ar(ID_W'(s), 64'h8000_2000 + (64'(s) << 3), 1'b0);
    end
`ifndef G6LC_TB_ATOMICS_WRAP
    repeat (4) tick;
    slv.ar_id = ID_W'(MAX); slv.ar_addr = 64'h8000_2100; slv.ar_valid = 1'b1;
    begin
      int unsigned k;
      for (k = 0; k < 16; k++) begin
        #0;
        if (slv.ar_ready) begin $error("9th AR ready"); errors++; end
        tick;
      end
    end
    slv.ar_valid = 1'b0;
`endif
    slv.r_ready = 1'b1; r_go = 1'b1;
    begin
      logic [7:0] got;
      int unsigned tlim, s;
      got = '0; tlim = cycles + 400;
      while ((got != 8'hFF) && cycles < tlim) begin
        #0;
        if (slv.r_valid) begin
          s = int'(slv.r_id);
          if (s > 7) begin $error("R id=%h", slv.r_id); errors++; end
          else got[s] = 1'b1;
        end
        tick;
      end
      if (got != 8'hFF) begin $error("R timeout got=%b", got); errors++; end
    end
    r_go = 1'b0;

    // Eight regular AW, 9th backpressure.
    slv.b_ready = 1'b0;
    begin
      int unsigned s;
      for (s = 0; s < MAX; s++)
        issue_aw_w(ID_W'(s), 64'h8000_3000 + (64'(s) << 3), 64'(s), 1'b0);
    end
`ifndef G6LC_TB_ATOMICS_WRAP
    repeat (4) tick;
    slv.aw_id = ID_W'(MAX); slv.aw_addr = 64'h8000_3100; slv.aw_valid = 1'b1;
    slv.w_valid = 1'b1; slv.w_last = 1'b1;
    begin
      int unsigned k;
      for (k = 0; k < 16; k++) begin
        #0;
        if (slv.aw_ready) begin $error("9th AW ready"); errors++; end
        tick;
      end
    end
    slv.aw_valid = 1'b0; slv.w_valid = 1'b0;
`endif
    slv.b_ready = 1'b1; b_go = 1'b1;
    begin
      logic [7:0] got;
      int unsigned tlim, s;
      got = '0; tlim = cycles + 400;
      while ((got != 8'hFF) && cycles < tlim) begin
        #0;
        if (slv.b_valid) begin
          s = int'(slv.b_id);
          if (s > 7) begin $error("B id=%h", slv.b_id); errors++; end
          else got[s] = 1'b1;
        end
        tick;
      end
      if (got != 8'hFF) begin $error("B timeout got=%b", got); errors++; end
    end

    // Drain leftover slv B after eight AW, then LR/SC (lrsc now sits
    // above AMOS so AxLOCK is visible).
    begin
      int unsigned idle;
      idle = 0;
      while (idle < 16) begin
        #0;
        if (slv.b_valid) idle = 0;
        else idle++;
        tick;
      end
    end

    begin
      int unsigned stores0;
      stores0 = nstore;
      r_go = 1'b1;
      issue_ar(6'h11, 64'h8000_4000, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        if (!slv.r_valid || slv.r_resp !== 2'b01) begin
          $error("LR resp=%h", slv.r_resp); errors++;
        end
        tick;
      end
      repeat (8) tick;
      issue_aw_w(6'h11, 64'h8000_4000, 64'h1111, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0;
        while ((!(slv.b_valid && slv.b_id == 6'h11)) && cycles < tlim) tick;
        if (!slv.b_valid || slv.b_id !== 6'h11 || slv.b_resp !== 2'b01) begin
          $error("SC ok id=%h resp=%h", slv.b_id, slv.b_resp); errors++;
        end
        tick;
      end
      if (nstore != stores0 + 1) begin
        $error("SC success must store"); errors++;
      end
    end

    // Split-ID LR/SC: HPDCACHE LDEX uses the read ID space, STEX uses
    // uncached-write id='1. Reservation is address-only.
    begin
      int unsigned stores0;
      stores0 = nstore;
      r_go = 1'b1;
      issue_ar(6'h05, 64'h8000_6000, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        if (!slv.r_valid || slv.r_resp !== 2'b01) begin
          $error("split LR resp=%h", slv.r_resp); errors++;
        end
        tick;
      end
      issue_aw_w(6'h3F, 64'h8000_6000, 64'h3333, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0;
        while ((!(slv.b_valid && slv.b_id == 6'h3F)) && cycles < tlim) tick;
        if (!slv.b_valid || slv.b_id !== 6'h3F || slv.b_resp !== 2'b01) begin
          $error("split SC id=%h resp=%h", slv.b_id, slv.b_resp); errors++;
        end
        tick;
      end
      if (nstore != stores0 + 1) begin
        $error("split SC must store"); errors++;
      end
    end

    // LR + intervening store + SC fail (no downstream write).
    begin
      int unsigned stores0;
      stores0 = nstore;
      issue_ar(6'h22, 64'h8000_5000, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        tick;
      end
      issue_aw_w(6'h03, 64'h8000_5000, 64'hBEEF, 1'b0);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.b_valid && cycles < tlim) tick;
        tick;
      end
      issue_aw_w(6'h22, 64'h8000_5000, 64'h2222, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while ((!(slv.b_valid && slv.b_id == 6'h22)) && cycles < tlim) tick;
        if (!slv.b_valid || slv.b_id !== 6'h22 || slv.b_resp !== 2'b00) begin
          $error("SC fail id=%h resp=%h", slv.b_id, slv.b_resp); errors++;
        end
        tick;
      end
      if (nstore != stores0 + 1) begin
        $error("SC fail must not store nstore=%0d", nstore); errors++;
      end
    end

    // Disjoint reservations: two agents reserve DIFFERENT addresses, then each
    // completes its own SC. Both must succeed -- nothing wrote either address.
    //
    // This is the case the single-reservation monitor fails and that the
    // same-address snoop test above cannot detect, because only one line is in
    // play there. With NRES=1 the second LR destroys the first reservation and
    // the first SC returns OKAY instead of EXOKAY, which is the livelock two
    // harts hit on unrelated spinlocks. Build with
    // `+define+G6LC_TB_LRSC_SINGLE_RES` to observe exactly that.
    begin
      int unsigned stores0;
      stores0 = nstore;
      // A reserves 0x8000_7000.
      issue_ar(6'h12, 64'h8000_7000, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        tick;
      end
      // B reserves a different line, inside A's LR..SC window.
      issue_ar(6'h13, 64'h8000_7100, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        tick;
      end
      // A's SC must still succeed.
      issue_aw_w(6'h12, 64'h8000_7000, 64'h7777, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while ((!(slv.b_valid && slv.b_id == 6'h12)) && cycles < tlim) tick;
        if (!slv.b_valid || slv.b_id !== 6'h12 || slv.b_resp !== 2'b01) begin
          $error("disjoint SC A id=%h resp=%h (expected EXOKAY; a peer LR to another address must not clear this reservation)",
                 slv.b_id, slv.b_resp);
          errors++;
        end
        tick;
      end
      // B's SC must also succeed.
      issue_aw_w(6'h13, 64'h8000_7100, 64'h8888, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while ((!(slv.b_valid && slv.b_id == 6'h13)) && cycles < tlim) tick;
        if (!slv.b_valid || slv.b_id !== 6'h13 || slv.b_resp !== 2'b01) begin
          $error("disjoint SC B id=%h resp=%h (expected EXOKAY)", slv.b_id, slv.b_resp);
          errors++;
        end
        tick;
      end
      // Both SCs succeeded, so both must have written downstream.
      if (nstore != stores0 + 2) begin
        $error("disjoint SCs must both store nstore=%0d expected=%0d", nstore, stores0 + 2);
        errors++;
      end
    end

    // Same address, two reservations: exactly one SC may win. Guards against
    // "fix" the other way -- a table that simply never clears would let both
    // succeed and silently break mutual exclusion.
    begin
      logic first_ok, second_ok;
      issue_ar(6'h14, 64'h8000_7200, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        tick;
      end
      issue_ar(6'h15, 64'h8000_7200, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while (!slv.r_valid && cycles < tlim) tick;
        tick;
      end
      issue_aw_w(6'h14, 64'h8000_7200, 64'h9999, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while ((!(slv.b_valid && slv.b_id == 6'h14)) && cycles < tlim) tick;
        first_ok = slv.b_valid && (slv.b_resp === 2'b01);
        tick;
      end
      issue_aw_w(6'h15, 64'h8000_7200, 64'hAAAA, 1'b1);
      begin
        int unsigned tlim;
        tlim = cycles + 400;
        #0; while ((!(slv.b_valid && slv.b_id == 6'h15)) && cycles < tlim) tick;
        second_ok = slv.b_valid && (slv.b_resp === 2'b01);
        tick;
      end
      if (first_ok === second_ok) begin
        $error("same-address SCs: exactly one must win (first=%0b second=%0b)", first_ok, second_ok);
        errors++;
      end
    end

    if (errors == 0)
`ifdef G6LC_TB_ATOMICS_WRAP
      $display("PASS g6lc_axi_atomics_wrap ar8 aw8 cycles=%0d", cycles);
`else
      $display("PASS g6lc_axi_lrsc ar8 aw8 cycles=%0d", cycles);
`endif
    else begin
      $display("FAIL g6lc_axi_lrsc errors=%0d", errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
