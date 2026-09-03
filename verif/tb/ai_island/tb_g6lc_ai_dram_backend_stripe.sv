// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// Class-0 striped SRAM on the shared DRAM slave.
// Default NCH=2; -GNCH=4/8 is S7-lite. S4-mshr: 8 IDs in flight (MAX_TRANS).

`timescale 1ns/1ps
`include "axi/assign.svh"

module tb_g6lc_ai_dram_backend_stripe
  import g6lc_ai_island_cfg_pkg::*;
#(
    parameter int unsigned NCH = 2
);
  localparam int unsigned ID_W   = 4;
  localparam int unsigned ADDR_W = 64;
  localparam int unsigned DATA_W = 64;
  localparam int unsigned NWORDS = 1024;
  localparam logic [ID_W-1:0] CORE_ID = 4'h1;
  localparam logic [ID_W-1:0] ISL_ID  = 4'h2;
  localparam int unsigned TO_HS  = 8000;
  localparam int unsigned TO_RSP = 16000;

  logic clk, rst_ni, init_done;
  logic aw_pend, w_pend, ar_pend;
  logic aw_set, w_set, ar_set;
  logic b_ready_en, r_ready_en, resp_clr;
  logic [1:0] b_got, r_got;
  logic [DATA_W-1:0] r_cap0, r_cap1;
  logic [AI_DRAM_MAX_CHANNELS-1:0][31:0] ch_r_beats, ch_w_beats;
  int unsigned errors, cycles;

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_ID_WIDTH   ( ID_W   ),
      .AXI_USER_WIDTH ( 1      )
  ) dram();

  g6lc_ai_dram_backend #(
      .DramClass      ( AI_DRAM_SIM_AXI ),
      .AXI_ID_WIDTH   ( ID_W ),
      .AXI_ADDR_WIDTH ( ADDR_W ),
      .AXI_DATA_WIDTH ( DATA_W ),
      .AXI_USER_WIDTH ( 1 ),
      .AXI_USER_EN    ( 0 ),
      .NUM_WORDS      ( NWORDS ),
      .NrChannels     ( NCH ),
      .ChanShift      ( AI_DRAM_CHAN_SHIFT_DEFAULT )
  ) i_dut (
      .clk_i        ( clk ),
      .rst_ni       ( rst_ni ),
      .rst_sram_ni  ( rst_ni ),
      .testmode_i   ( 1'b0 ),
      .slave        ( dram ),
      .init_done_o  ( init_done ),
      .ch_r_beats_o ( ch_r_beats ),
      .ch_w_beats_o ( ch_w_beats )
  );

  initial clk = 0;
  always #5 clk = ~clk;

  assign dram.aw_valid = aw_pend;
  assign dram.w_valid  = w_pend;
  assign dram.ar_valid = ar_pend;
  assign dram.b_ready  = b_ready_en;
  assign dram.r_ready  = r_ready_en;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_pend <= 1'b0;
      w_pend  <= 1'b0;
      ar_pend <= 1'b0;
      b_got   <= '0;
      r_got   <= '0;
      r_cap0  <= '0;
      r_cap1  <= '0;
    end else begin
      if (aw_set) aw_pend <= 1'b1;
      else if (aw_pend && dram.aw_ready) aw_pend <= 1'b0;
      if (w_set) w_pend <= 1'b1;
      else if (w_pend && dram.w_ready) w_pend <= 1'b0;
      if (ar_set) ar_pend <= 1'b1;
      else if (ar_pend && dram.ar_ready) ar_pend <= 1'b0;
      if (resp_clr) begin
        b_got  <= '0;
        r_got  <= '0;
        r_cap0 <= '0;
        r_cap1 <= '0;
      end else begin
        if (dram.b_valid && dram.b_ready) begin
          if (dram.b_id == CORE_ID) b_got[0] <= 1'b1;
          else if (dram.b_id == ISL_ID) b_got[1] <= 1'b1;
        end
        if (dram.r_valid && dram.r_ready) begin
          if (dram.r_id == CORE_ID) begin
            r_got[0] <= 1'b1;
            r_cap0   <= dram.r_data;
          end else if (dram.r_id == ISL_ID) begin
            r_got[1] <= 1'b1;
            r_cap1   <= dram.r_data;
          end
        end
      end
    end
  end

  function automatic logic [DATA_W-1:0] line_data(
      input logic [ID_W-1:0] id, input int unsigned beat
  );
    return {32'hC0DE_0000, 16'(id), 16'(beat)};
  endfunction

  task automatic tick;
    @(posedge clk);
    cycles++;
  endtask

  task automatic idle_payload;
    dram.aw_id     = '0;
    dram.aw_addr   = '0;
    dram.aw_len    = '0;
    dram.aw_size   = 3'd3;
    dram.aw_burst  = 2'b01;
    dram.aw_lock   = 1'b0;
    dram.aw_cache  = '0;
    dram.aw_prot   = '0;
    dram.aw_qos    = '0;
    dram.aw_region = '0;
    dram.aw_atop   = '0;
    dram.aw_user   = '0;
    dram.w_data    = '0;
    dram.w_strb    = 8'hFF;
    dram.w_last    = 1'b1;
    dram.w_user    = '0;
    dram.ar_id     = '0;
    dram.ar_addr   = '0;
    dram.ar_len    = '0;
    dram.ar_size   = 3'd3;
    dram.ar_burst  = 2'b01;
    dram.ar_lock   = 1'b0;
    dram.ar_cache  = '0;
    dram.ar_prot   = '0;
    dram.ar_qos    = '0;
    dram.ar_region = '0;
    dram.ar_user   = '0;
  endtask

  task automatic issue_aw(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [7:0]        len
  );
    dram.aw_id   = id;
    dram.aw_addr = addr;
    dram.aw_len  = len;
    aw_set = 1'b1;
    tick;
    aw_set = 1'b0;
    while (aw_pend && cycles < TO_HS) tick;
    if (aw_pend) begin
      $error("timeout AW addr=%h", addr);
      errors++;
    end
    dram.aw_len = '0;
  endtask

  task automatic issue_w(
      input logic [DATA_W-1:0] data,
      input logic              last
  );
    dram.w_data = data;
    dram.w_last = last;
    w_set = 1'b1;
    tick;
    w_set = 1'b0;
    while (w_pend && cycles < TO_HS) tick;
    if (w_pend) begin
      $error("timeout W");
      errors++;
    end
    dram.w_last = 1'b1;
  endtask

  task automatic issue_aw_w(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [DATA_W-1:0] data
  );
    issue_aw(id, addr, 8'd0);
    issue_w(data, 1'b1);
  endtask

  task automatic issue_ar(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [7:0]        len
  );
    dram.ar_id   = id;
    dram.ar_addr = addr;
    dram.ar_len  = len;
    ar_set = 1'b1;
    tick;
    ar_set = 1'b0;
    while (ar_pend && cycles < TO_HS) tick;
    if (ar_pend) begin
      $error("timeout AR addr=%h", addr);
      errors++;
    end
    dram.ar_len = '0;
  endtask

  task automatic wr_beat(
      input logic [ID_W-1:0]   id,
      input logic [ADDR_W-1:0] addr,
      input logic [DATA_W-1:0] data
  );
    issue_aw_w(id, addr, data);
    while (!dram.b_valid && cycles < TO_RSP) tick;
    if (!dram.b_valid) begin
      $error("timeout B addr=%h", addr);
      errors++;
    end
    tick;
  endtask

  task automatic rd_beat(
      input logic [ADDR_W-1:0] addr,
      input logic [DATA_W-1:0] exp
  );
    issue_ar('0, addr, 8'd0);
    while (!dram.r_valid && cycles < TO_RSP) tick;
    if (!dram.r_valid) begin
      $error("timeout R addr=%h", addr);
      errors++;
    end else if (dram.r_data !== exp) begin
      $error("data mismatch addr=%h exp=%h got=%h", addr, exp, dram.r_data);
      errors++;
    end
    tick;
  endtask

  task automatic arm_resp;
    resp_clr = 1'b1;
    tick;
    resp_clr = 1'b0;
  endtask

  task automatic collect_line_pair;
    int unsigned n0, n1;
    logic [DATA_W-1:0] exp;
    n0 = 0;
    n1 = 0;
    while ((n0 < 8 || n1 < 8) && cycles < TO_RSP) begin
      if (dram.r_valid) begin
        if (dram.r_id == CORE_ID && n0 < 8) begin
          exp = line_data(CORE_ID, n0);
          if (dram.r_data !== exp) begin
            $error("line ch0 beat=%0d exp=%h got=%h", n0, exp, dram.r_data);
            errors++;
          end
          if (dram.r_last !== (n0 == 7)) begin
            $error("line ch0 last beat=%0d", n0);
            errors++;
          end
          n0++;
        end else if (dram.r_id == ISL_ID && n1 < 8) begin
          exp = line_data(ISL_ID, n1);
          if (dram.r_data !== exp) begin
            $error("line ch1 beat=%0d exp=%h got=%h", n1, exp, dram.r_data);
            errors++;
          end
          if (dram.r_last !== (n1 == 7)) begin
            $error("line ch1 last beat=%0d", n1);
            errors++;
          end
          n1++;
        end else begin
          $error("line unexpected R id=%h", dram.r_id);
          errors++;
        end
      end
      tick;
    end
    if (n0 != 8 || n1 != 8) begin
      $error("timeout line R n0=%0d n1=%0d", n0, n1);
      errors++;
    end
  endtask

  function automatic logic [ADDR_W-1:0] mshr_addr(input int unsigned i);
    return 64'h8000_0300 + (i << 6);
  endfunction

  function automatic logic [DATA_W-1:0] mshr_data(input int unsigned idn);
    return {32'hA5A5_0000, 16'(idn), 16'h0008};
  endfunction

  task automatic collect_mshr_b(input int unsigned n);
    logic [7:0] got, need;
    int unsigned idn;
    got  = '0;
    need = 8'((32'h1 << n) - 32'h1);
    while ((got != need) && cycles < TO_RSP) begin
      if (dram.b_valid) begin
        idn = unsigned'(dram.b_id);
        if (idn < 1 || idn > n) begin
          $error("mshr unexpected B id=%h", dram.b_id);
          errors++;
        end else if (got[idn-1]) begin
          $error("mshr duplicate B id=%0d", idn);
          errors++;
        end else
          got[idn-1] = 1'b1;
      end
      tick;
    end
    if (got != need) begin
      $error("timeout mshr B got=%b need=%b", got, need);
      errors++;
    end
  endtask

  task automatic collect_mshr_r(input int unsigned n);
    logic [7:0] got, need;
    int unsigned idn;
    got  = '0;
    need = 8'((32'h1 << n) - 32'h1);
    while ((got != need) && cycles < TO_RSP) begin
      if (dram.r_valid) begin
        idn = unsigned'(dram.r_id);
        if (idn < 1 || idn > n) begin
          $error("mshr unexpected R id=%h", dram.r_id);
          errors++;
        end else if (got[idn-1]) begin
          $error("mshr duplicate R id=%0d", idn);
          errors++;
        end else begin
          if (dram.r_data !== mshr_data(idn)) begin
            $error("mshr R id=%0d exp=%h got=%h", idn, mshr_data(idn), dram.r_data);
            errors++;
          end
          got[idn-1] = 1'b1;
        end
      end
      tick;
    end
    if (got != need) begin
      $error("timeout mshr R got=%b need=%b", got, need);
      errors++;
    end
  endtask

  initial begin
    int unsigned i;
    errors     = 0;
    cycles     = 0;
    rst_ni     = 1'b0;
    aw_set     = 1'b0;
    w_set      = 1'b0;
    ar_set     = 1'b0;
    resp_clr   = 1'b0;
    b_ready_en = 1'b1;
    r_ready_en = 1'b1;
    idle_payload();
    repeat (4) tick;
    rst_ni = 1'b1;
    repeat (8) tick;

    if (!init_done) begin
      $error("class-0 init_done must be 1");
      errors++;
    end
    if (!dram_channels_ok(NCH)) begin
      $error("NCH=%0d not in {1,2,4,8}", NCH);
      errors++;
    end

    wr_beat(CORE_ID, 64'h8000_0000, 64'h1111_1111_1111_1111);
    wr_beat(ISL_ID,  64'h8000_0040, 64'h2222_2222_2222_2222);
    rd_beat(64'h8000_0000, 64'h1111_1111_1111_1111);
    rd_beat(64'h8000_0040, 64'h2222_2222_2222_2222);
    wr_beat(CORE_ID, 64'h8000_0008, 64'hAAAA_0008_AAAA_0008);
    wr_beat(ISL_ID,  64'h8000_0048, 64'hBBBB_0048_BBBB_0048);
    rd_beat(64'h8000_0008, 64'hAAAA_0008_AAAA_0008);
    rd_beat(64'h8000_0048, 64'hBBBB_0048_BBBB_0048);
    rd_beat(64'h8000_0000, 64'h1111_1111_1111_1111);

    // Consecutive 64 B lines: N=2 → ch0/ch1; N=4 → ch2/ch3 (addr[7:6]).
    wr_beat(4'h3, 64'h8000_0080, 64'h3333_3333_3333_3333);
    wr_beat(4'h3, 64'h8000_00C0, 64'h4444_4444_4444_4444);
    rd_beat(64'h8000_0080, 64'h3333_3333_3333_3333);
    rd_beat(64'h8000_00C0, 64'h4444_4444_4444_4444);

    // S4-lite: two IDs outstanding (single beat).
    b_ready_en = 1'b0;
    arm_resp();
    issue_aw_w(CORE_ID, 64'h8000_0100, 64'h5555_5555_5555_5555);
    issue_aw_w(ISL_ID,  64'h8000_0140, 64'h6666_6666_6666_6666);
    b_ready_en = 1'b1;
    while ((b_got != 2'b11) && cycles < TO_RSP) tick;
    if (b_got != 2'b11) begin
      $error("timeout concurrent B got=%b", b_got);
      errors++;
    end
    tick;

    r_ready_en = 1'b0;
    arm_resp();
    issue_ar(CORE_ID, 64'h8000_0100, 8'd0);
    issue_ar(ISL_ID,  64'h8000_0140, 8'd0);
    r_ready_en = 1'b1;
    while ((r_got != 2'b11) && cycles < TO_RSP) tick;
    if (r_got != 2'b11) begin
      $error("timeout concurrent R got=%b", r_got);
      errors++;
    end else begin
      if (r_cap0 !== 64'h5555_5555_5555_5555) begin
        $error("concurrent ch0 exp=5555 got=%h", r_cap0);
        errors++;
      end
      if (r_cap1 !== 64'h6666_6666_6666_6666) begin
        $error("concurrent ch1 exp=6666 got=%h", r_cap1);
        errors++;
      end
    end
    tick;

    // S4-line: concurrent 64 B INCR (L2 fill) to two stripes.
    b_ready_en = 1'b0;
    arm_resp();
    issue_aw(CORE_ID, 64'h8000_0200, 8'd7);
    issue_aw(ISL_ID,  64'h8000_0240, 8'd7);
    for (i = 0; i < 8; i++)
      issue_w(line_data(CORE_ID, i), (i == 7));
    for (i = 0; i < 8; i++)
      issue_w(line_data(ISL_ID, i), (i == 7));
    b_ready_en = 1'b1;
    while ((b_got != 2'b11) && cycles < TO_RSP) tick;
    if (b_got != 2'b11) begin
      $error("timeout line B got=%b", b_got);
      errors++;
    end
    tick;

    r_ready_en = 1'b0;
    issue_ar(CORE_ID, 64'h8000_0200, 8'd7);
    issue_ar(ISL_ID,  64'h8000_0240, 8'd7);
    r_ready_en = 1'b1;
    collect_line_pair();

    // S4-mshr (SRAM): one outstanding per channel. axi2mem is shallow;
    // 8-in-flight on two SRAMs deadlocks with B held. N=8 → 8 IDs.
    b_ready_en = 1'b0;
    for (i = 0; i < NCH; i++)
      issue_aw_w(ID_W'(i + 1), mshr_addr(i), mshr_data(i + 1));
    b_ready_en = 1'b1;
    collect_mshr_b(NCH);

    r_ready_en = 1'b0;
    for (i = 0; i < NCH; i++)
      issue_ar(ID_W'(i + 1), mshr_addr(i), 8'd0);
    r_ready_en = 1'b1;
    collect_mshr_r(NCH);

    if (ch_w_beats[0] == 0 || ch_w_beats[1] == 0 ||
        ch_r_beats[0] == 0 || ch_r_beats[1] == 0) begin
      $error("S5 occupancy silent ch w=%0d/%0d r=%0d/%0d",
             ch_w_beats[0], ch_w_beats[1], ch_r_beats[0], ch_r_beats[1]);
      errors++;
    end
    if (NCH >= 4 &&
        (ch_w_beats[2] == 0 || ch_w_beats[3] == 0 ||
         ch_r_beats[2] == 0 || ch_r_beats[3] == 0)) begin
      $error("S7-lite N=4 silent ch2/3 w=%0d/%0d r=%0d/%0d",
             ch_w_beats[2], ch_w_beats[3], ch_r_beats[2], ch_r_beats[3]);
      errors++;
    end
    if (NCH >= 8) begin
      for (i = 0; i < 8; i++) begin
        if (ch_w_beats[i] == 0 || ch_r_beats[i] == 0) begin
          $error("S7-lite N=8 silent ch%0d w=%0d r=%0d",
                 i, ch_w_beats[i], ch_r_beats[i]);
          errors++;
        end
      end
    end

    if (errors == 0)
      $display("PASS g6lc_ai_dram_backend_stripe nch=%0d s4mshr cycles=%0d w=%0d/%0d r=%0d/%0d",
               NCH, cycles, ch_w_beats[0], ch_w_beats[1], ch_r_beats[0], ch_r_beats[1]);
    else begin
      $display("FAIL g6lc_ai_dram_backend_stripe nch=%0d errors=%0d", NCH, errors);
      $fatal(1);
    end
    $finish;
  end
endmodule
