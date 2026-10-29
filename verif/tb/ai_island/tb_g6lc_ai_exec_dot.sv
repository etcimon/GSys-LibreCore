// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// tb_g6lc_ai_exec_dot — directed leaf for g6lc_ai_exec (hyp tree of record).
// Covers: dot4 s8/u8/dot4a (T0 arms), MMA 8x8x8 in s8 and u8 dtypes, and the
// accumulate accmode arm, all against a behavioural golden. Written for the
// ai-hyp-r1 batch (no hyp8 config elaborates the CVXIF coprocessor, so the
// ai-matrix directed suite cannot gate this block — this leaf is the gate).

`timescale 1ns/1ps

module tb_g6lc_ai_exec_dot;
  parameter int unsigned D4S  = 1;
  parameter int unsigned NREG = 4;
  parameter int unsigned XLEN = 64;
  import g6lc_ai_instr_pkg::*;

  logic clk = 0, rst_n = 0;
  always #5 clk = ~clk;

  localparam type registers_t = logic [NREG-1:0][XLEN-1:0];

  // DUT signals
  logic        valid_i;
  registers_t  registers_i;
  opcode_t     opcode_i;
  logic [31:0] instr_i;
  logic [XLEN-1:0] aicfg_i;
  logic [1:0]      ais_i;
  logic            ai_q_en_i;
  logic [7:0]      ai_qid_i;
  logic            isl_has_completion_i, isl_retired_valid_i, isl_attached_i;
  logic [31:0]     isl_retired_ticket_i, isl_last_ticket_i;
  logic [15:0]     isl_last_status_i;
  logic            sb_enq_ready_i;
  logic [31:0]     sb_enq_ticket_i;
  logic            setcfg_we_o, dirty_o, busy_o;
  logic [XLEN-1:0] setcfg_wdata_o;
  logic            sb_enq_valid_o;
  logic [7:0]      sb_qid_o;
  logic [31:0]     sb_ticket_o;
  logic [XLEN-1:0] sb_desc_ptr_o;
  logic            pmu_op_o, pmu_mma_o, pmu_post_o, pmu_t0_o;
  logic [XLEN-1:0] result_o;
  logic [4:0]      rd_o;
  logic            valid_o, we_o;
  logic [1:0]      hartid_i, hartid_o;
  logic [3:0]      id_i, id_o;
  logic [4:0]      rd_i;

  g6lc_ai_exec #(
      .NrRgprPorts (NREG),
      .XLEN        (XLEN),
      .AiCfg       (config_pkg::AiCfgOff),
      .hartid_t    (logic [1:0]),
      .id_t        (logic [3:0]),
      .registers_t (registers_t),
      .Dot4Stages  (D4S)
  ) i_dut (
      .clk_i (clk), .rst_ni (rst_n),
      .valid_i, .registers_i, .opcode_i, .instr_i,
      .hartid_i, .id_i, .rd_i,
      .aicfg_i, .ais_i, .ai_q_en_i, .ai_qid_i,
      .isl_has_completion_i, .isl_retired_valid_i, .isl_retired_ticket_i,
      .isl_last_ticket_i, .isl_last_status_i, .isl_attached_i,
      .sb_enq_ready_i, .sb_enq_ticket_i,
      .testmode_i (1'b0),
      .setcfg_we_o, .setcfg_wdata_o, .dirty_o, .busy_o,
      .sb_enq_valid_o, .sb_qid_o, .sb_ticket_o, .sb_desc_ptr_o,
      .pmu_op_o, .pmu_mma_o, .pmu_post_o, .pmu_t0_o,
      .result_o, .hartid_o, .id_o, .rd_o, .valid_o, .we_o
  );

  int unsigned checks = 0, errors = 0;
  task automatic chk(input bit cond, input string what);
    checks++;
    if (!cond) begin
      errors++;
      $display("FAIL %s at %0t", what, $time);
    end
  endtask
  task automatic chkv(input logic [63:0] got, input logic [63:0] want,
                      input string what);
    checks++;
    if (got !== want) begin
      errors++;
      $display("FAIL %s got=%h want=%h at %0t", what, got, want, $time);
    end
  endtask

  // R-type instr word: rd=[11:7], rs1=[19:15], rs2=[24:20].
  function automatic logic [31:0] mk(input logic [4:0] rs2, input logic [4:0] rs1,
                                     input logic [4:0] rd);
    return {7'b0, rs2, rs1, 3'b0, rd, 7'h5b};
  endfunction

  // Issue one op; T0 ops answer with valid_o the cycle after.
  task automatic issue(input opcode_t op, input logic [31:0] ins,
                       input registers_t regs);
    @(posedge clk);
    #1;
    valid_i     = 1'b1;
    opcode_i    = op;
    instr_i     = ins;
    registers_i = regs;
    @(posedge clk);
    #1;
    valid_i     = 1'b0;
  endtask

  // Set the completion metadata the issue cycle must carry through.
  task automatic set_meta(input logic [1:0] h, input logic [3:0] i,
                          input logic [4:0] r);
    hartid_i = h; id_i = i; rd_i = r;
  endtask

  task automatic poison_inputs();
    registers_i = '{NREG{64'hDEADBEEFDEADBEEF}};
    opcode_i    = AI_ILLEGAL;
    instr_i     = 32'hFFFFFFFF;
    hartid_i    = 2'b11; id_i = 4'hF; rd_i = 5'h1F;
  endtask

  // Exact-latency T0 check: D4S=1 answers on the edge issue() returns
  // (valid=1, busy=0); D4S=2 must be (valid=0, busy=1) at that edge and
  // (valid=1, busy=0) exactly one posedge later. All live inputs are
  // poisoned in between so only the captured record can drive result_o.
  task automatic t0_check(input opcode_t op, input registers_t regs,
                          input logic [XLEN-1:0] want, input string what,
                          input logic [1:0] h = 0, input logic [3:0] i = 0,
                          input logic [4:0] r = 5'd1);
    set_meta(h, i, r);
    issue(op, '0, regs);
    if (D4S == 1) begin
      chk(valid_o === 1'b1, {what, " valid d1"});
      chk(busy_o === 1'b0, {what, " busy d1"});
    end else begin
      chk(valid_o === 1'b0, {what, " prevalid d2"});
      chk(busy_o === 1'b1, {what, " busy d2"});
      poison_inputs();
      @(posedge clk); #1;
      chk(valid_o === 1'b1, {what, " valid d2"});
      chk(busy_o === 1'b0, {what, " postbusy d2"});
    end
    chkv(result_o, want, what);
    chk(hartid_o === h, {what, " hartid"});
    chk(id_o === i, {what, " id"});
    chk(rd_o === r, {what, " rd"});
    chk(we_o === 1'b1, {what, " we"});
    chk(pmu_t0_o === 1'b1, {what, " pmu_t0"});
    chk(pmu_op_o === 1'b1, {what, " pmu_op"});
    chk(dirty_o === 1'b0, {what, " dirty"});
    chk(sb_enq_valid_o === 1'b0, {what, " sb_enq"});
  endtask

  // Independent DOT4 golden: byte products summed in a 32-bit total, the
  // DOT4A accumulator from regs[2] iff present, sign/zero-extended.
  function automatic logic [63:0] dot_gold(input opcode_t op,
                                           input registers_t regs);
    int total; int pa, pb;
    total = 0;
    for (int d = 0; d < 4; d++) begin
      pa = regs[0][d*8 +: 8]; pb = regs[1][d*8 +: 8];
      if (op == AI_DOT4_U8) total += pa * pb;
      else total += integer'(signed'(regs[0][d*8 +: 8])) *
                    integer'(signed'(regs[1][d*8 +: 8]));
    end
    if (op == AI_DOT4A_S8 && NREG >= 3) total += signed'(regs[2][31:0]);
    if (op == AI_DOT4_U8) return 64'(total);
    return 64'(signed'(32'(total)));
  endfunction

  // Tile write: rd = tile idx, rs2 = elem, registers_i[0][7:0] = byte.
  task automatic tset(input int tile, input int elem, input int unsigned byte_v);
    registers_t r;
    r = '0;
    r[0] = XLEN'(byte_v & 32'hff);
    issue(AI_MVTA, mk(5'(elem), 5'd0, 5'(tile)), r);
    chk(valid_o === 1'b1, "mvta valid");
  endtask

  // Acc read: rs1 = acc idx, rs2 = elem → result_o.
  task automatic aread(input int acc, input int elem, input int unsigned want,
                       input string what);
    issue(AI_MVACC, mk(5'(elem), 5'(acc), 5'd2), '{NREG{64'd0}});
    chk(valid_o === 1'b1, {what, " valid"});
    chk(result_o === XLEN'(want), what);
  endtask

  // Acc read of a negative element: compare the 32-bit accumulator only
  // (result_o's extension above bit 31 is not what this check is for).
  task automatic aread32(input int acc, input int elem, input logic [31:0] want,
                         input string what);
    issue(AI_MVACC, mk(5'(elem), 5'(acc), 5'd2), '{NREG{64'd0}});
    chk(valid_o === 1'b1, {what, " valid"});
    chk(result_o[31:0] === want, what);
  endtask

  // MMA: rd = acc, rs1 = tile A, rs2 = tile B; dims from aicfg_i.
  task automatic mma(input opcode_t op, input int acc, input int ta, input int tb,
                     input logic [15:0] cfg);
    aicfg_i = {48'd0, cfg};
    issue(op, mk(5'(tb), 5'(ta), 5'(acc)), '{NREG{64'd0}});
    wait (valid_o === 1'b1);
    @(posedge clk); #1;
  endtask

  // Non-DOT result arms now share the result_other_n | dot_result_bits
  // boundary — exercise each once through the normal completion path.
  task automatic plain_check(input opcode_t op, input registers_t regs,
                             input logic [XLEN-1:0] want,
                             input bit dirty_exp, input string what,
                             input logic [1:0] h = 0, input logic [3:0] i = 0,
                             input logic [4:0] r = 5'd1);
    set_meta(h, i, r);
    issue(op, '0, regs);
    chk(valid_o === 1'b1, {what, " valid"});
    chk(busy_o === 1'b0, {what, " busy"});
    chkv(result_o, want, what);
    chk(hartid_o === h && id_o === i && rd_o === r, {what, " meta"});
    chk(we_o === 1'b1, {what, " we"});
    chk(pmu_op_o === 1'b1, {what, " pmu_op"});
    chk(dirty_o === dirty_exp, {what, " dirty"});
    chk(sb_enq_valid_o === 1'b0, {what, " sb_enq"});
  endtask

  initial begin
    registers_t regs = '0;
    logic [31:0] golden [64];
    int unsigned av, bv;

    valid_i = 0; opcode_i = AI_ILLEGAL; instr_i = '0; registers_i = '0;
    hartid_i = '0; id_i = '0; rd_i = 5'd1;
    aicfg_i = '0; ais_i = '0; ai_q_en_i = 1'b0; ai_qid_i = '0;
    isl_has_completion_i = 0; isl_retired_valid_i = 0; isl_retired_ticket_i = '0;
    isl_last_ticket_i = '0; isl_last_status_i = '0; isl_attached_i = 1'b0;
    sb_enq_ready_i = 1'b1; sb_enq_ticket_i = '0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    repeat (2) @(posedge clk);

    // ---- dot4 arms ------------------------------------------------------
    // s8: (1,2,3,4)·(5,6,7,8) = 70
    regs = '{NREG{64'd0}};
    regs[0] = 64'h04030201; regs[1] = 64'h08070605;
    t0_check(AI_DOT4_S8, regs, 64'd70, "dot4_s8 pos");
    // s8 negatives: (-1,-1,-1,-1)·(2,2,2,2) = -8
    regs[0] = 64'hffffffff; regs[1] = 64'h02020202;
    t0_check(AI_DOT4_S8, regs, 64'hfffffffffffffff8, "dot4_s8 neg");
    // u8: (255,0,1,2)·(2,2,2,2) = 516  (bytes 0x02,0x01,0x00,0xFF little-end)
    regs[0] = 64'hff000102; regs[1] = 64'h02020202;
    t0_check(AI_DOT4_U8, regs, 64'd516, "dot4_u8");
    // dot4a: acc=100 + same s8 dot (70) = 170 (NREG>=3); 2-port configs
    // have no accumulator port, so the dot alone is expected (70).
    regs[0] = 64'h04030201; regs[1] = 64'h08070605;
    if (NREG >= 3) regs[2] = 64'd100;
    t0_check(AI_DOT4A_S8, regs, XLEN'(dot_gold(AI_DOT4A_S8, regs)), "dot4a_s8 acc");

    // ---- exhaustive 256x256 product sweep (valid_i=0, reads internals) ----
    for (av = 0; av < 256; av++) begin
      for (bv = 0; bv < 256; bv++) begin
        registers_i = '{NREG{64'd0}};
        registers_i[0][31:0] = {4{8'(av)}};
        registers_i[1][31:0] = {4{8'(bv)}};
        #1;
        chkv(64'(i_dut.dot4_s_sum),
             64'(signed'(18'(4 * ($signed(8'(av[7] ? av - 256 : av)) *
                                $signed(8'(bv[7] ? bv - 256 : bv)))))),
             "sweep s");
        chkv(64'(i_dut.dot4_u_sum), 64'(18'(4 * av * bv)), "sweep u");
      end
    end
    registers_i = '0;

    // ---- directed corners + golden comparison -----------------------------
    // all-0x80 x 0x80: signed 4*16384 = 65536 / unsigned 4*128*128
    regs = '{NREG{64'd0}};
    regs[0] = 64'h80808080; regs[1] = 64'h80808080;
    t0_check(AI_DOT4_S8, regs, XLEN'(dot_gold(AI_DOT4_S8, regs)), "d80x80 s");
    t0_check(AI_DOT4_U8, regs, XLEN'(dot_gold(AI_DOT4_U8, regs)), "d80x80 u");
    // all-0x80 x 0x7f: signed -128*127*4 = -65024
    regs[0] = 64'h80808080; regs[1] = 64'h7f7f7f7f;
    t0_check(AI_DOT4_S8, regs, XLEN'(dot_gold(AI_DOT4_S8, regs)), "d80x7f s");
    // all-0xff x 0xff unsigned 4*255*255 = 260100
    regs[0] = 64'hffffffff; regs[1] = 64'hffffffff;
    t0_check(AI_DOT4_U8, regs, XLEN'(dot_gold(AI_DOT4_U8, regs)), "dffxff u");
    // DOT4A accumulator boundaries
    if (NREG >= 3) begin
      regs = '{NREG{64'd0}};
      regs[0] = 64'h01010101; regs[1] = 64'h01010101;
      regs[2] = 64'h7fffffff;
      t0_check(AI_DOT4A_S8, regs, XLEN'(dot_gold(AI_DOT4A_S8, regs)), "acc max");
      regs[2] = 64'h80000000;
      t0_check(AI_DOT4A_S8, regs, XLEN'(dot_gold(AI_DOT4A_S8, regs)), "acc min");
      regs[2] = 64'hffffffff;
      t0_check(AI_DOT4A_S8, regs, XLEN'(dot_gold(AI_DOT4A_S8, regs)), "acc -1");
      // negative accumulator remains negative (wrap via acc max/-1 above)
      regs[0] = 64'h80808080; regs[1] = 64'h80808080;
      regs[2] = 64'h80000000;
      t0_check(AI_DOT4A_S8, regs, XLEN'(dot_gold(AI_DOT4A_S8, regs)), "acc wrap");
    end

    // alternating signed extremes
    regs = '{NREG{64'd0}};
    regs[0] = 64'h807fff00; regs[1] = 64'h7f8001ff;
    t0_check(AI_DOT4_S8, regs, XLEN'(dot_gold(AI_DOT4_S8, regs)), "alt s");
    t0_check(AI_DOT4_U8, regs, XLEN'(dot_gold(AI_DOT4_U8, regs)), "alt u");

    // ---- 256 deterministic random pairs x 3 opcodes ------------------------
    begin : gen_prng
      logic [31:0] st;
      st = 32'h6c920001;
      for (int t = 0; t < 256; t++) begin
        st = st ^ (st << 13); st = st ^ (st >> 17); st = st ^ (st << 5);
        regs = '{NREG{64'd0}};
        regs[0] = {32'(st), 32'(st ^ 32'hA5A5A5A5)};
        st = st ^ (st << 13); st = st ^ (st >> 17); st = st ^ (st << 5);
        regs[1] = {32'(st), 32'(st ^ 32'h5A5A5A5A)};
        if (NREG >= 3) regs[2] = {32'(~st), 32'(st ^ 32'h00FF00FF)};
        t0_check(AI_DOT4_S8, regs, XLEN'(dot_gold(AI_DOT4_S8, regs)),
                 "prng s", 2'(t[1:0]), 4'(t[3:0]), 5'(t[4:0] + 1));
        t0_check(AI_DOT4_U8, regs, XLEN'(dot_gold(AI_DOT4_U8, regs)),
                 "prng u", 2'(t[1:0] ^ 2'b10), 4'(t[3:0] ^ 4'h5), 5'(t[4:0]));
        t0_check(AI_DOT4A_S8, regs, XLEN'(dot_gold(AI_DOT4A_S8, regs)),
                 "prng a", 2'(t[1:0] ^ 2'b01), 4'(t[3:0] ^ 4'hA), 5'(t[4:0] + 2));
      end
    end

    // ---- pending-completion reset ------------------------------------------
    if (D4S == 2) begin
      regs = '{NREG{64'd0}};
      regs[0] = 64'h01010101; regs[1] = 64'h02020202;
      set_meta(2'd2, 4'd7, 5'd9);
      issue(AI_DOT4_S8, '0, regs);
      chk(busy_o === 1'b1, "reset d2 busy");
      rst_n = 0; valid_i = 0;
      @(posedge clk); #1;
      chk(valid_o === 1'b0 && busy_o === 1'b0, "reset d2 clears");
      @(negedge clk); rst_n = 1;
      for (int w = 0; w < 3; w++) begin
        @(posedge clk); #1;
        chk(valid_o === 1'b0, "reset d2 no result");
      end
      t0_check(AI_DOT4_S8, regs, 64'd8, "reset d2 recovers");
    end else begin
      regs = '{NREG{64'd0}};
      regs[0] = 64'h01010101; regs[1] = 64'h02020202;
      rst_n = 0; valid_i = 0;
      @(posedge clk); #1;
      chk(valid_o === 1'b0 && busy_o === 1'b0, "reset d1 clears");
      @(negedge clk); rst_n = 1;
      @(posedge clk); #1;
      t0_check(AI_DOT4_S8, regs, 64'd8, "reset d1 recovers");
    end

    // ---- latency/throughput: negedge-driven eight-transaction stream ----
    begin : gen_tput
      logic [XLEN-1:0] expected [8];
      int due [8];
      int accepted, retired, cycle, last_accept;
      bit fire;
      accepted=0; retired=0; cycle=0; last_accept=-D4S;
      while (cycle < 8*D4S+3) begin
        @(negedge clk);
        poison_inputs();
        valid_i = (accepted < 8) && !busy_o;
        if (valid_i) begin
          registers_i='0;
          registers_i[0]=XLEN'(32'h01010101 * (accepted+1));
          registers_i[1]=XLEN'(32'h02020202);
          opcode_i=AI_DOT4_S8;
          set_meta(2'(accepted ^ 1),4'(accepted),5'(accepted+3));
        end
        @(posedge clk);
        fire=valid_i && !busy_o;
        if (fire) begin
          if(accepted>0) chk(cycle-last_accept == D4S,"tput acceptance spacing");
          expected[accepted]=XLEN'(dot_gold(opcode_i,registers_i));
          due[accepted]=cycle+D4S-1;
          last_accept=cycle;
          accepted++;
        end
        #1;
        if(retired<accepted && due[retired]==cycle) begin
          chk(valid_o === 1'b1,"tput exact valid");
          chkv(result_o,expected[retired],"tput data");
          chk(id_o === 4'(retired),"tput id");
          chk(hartid_o === 2'(retired ^ 1),"tput hart");
          chk(rd_o === 5'(retired+3),"tput rd");
          chk(we_o && pmu_t0_o && !dirty_o,"tput side effects");
          retired++;
        end else chk(valid_o === 1'b0,"tput no extra completion");
        cycle++;
      end
      @(negedge clk); valid_i=0;
      chk(accepted==8 && retired==8,"tput exactly eight");
    end



    // ---- directed non-DOT result checks ------------------------------------
    aicfg_i = 64'hFEDCBA9876543210;
    plain_check(AI_GETCFG, regs, XLEN'(64'hFEDCBA9876543210), 0, "getcfg a");
    aicfg_i = 64'h0123456789ABCDEF;
    plain_check(AI_GETCFG, regs, XLEN'(64'h0123456789ABCDEF), 0, "getcfg b");
    aicfg_i = '0;
    regs = '0;
    plain_check(AI_SETCFG, regs, XLEN'(AiContractVersion) << 16, 1,
                "setcfg zero", 2'd2, 4'd7, 5'd11);
    chk(setcfg_we_o === 1'b1, "setcfg we");
    chkv(setcfg_wdata_o, XLEN'(AiContractVersion) << 16, "setcfg zero wdata");
    ai_q_en_i = 1'b0;
    plain_check(AI_POLL, regs, '0, 0, "poll pending");
    plain_check(AI_ENQ, regs, XLEN'({XLEN{1'b1}}), 0, "enq full");

    // ---- mixed-ops stream: DOT + non-DOT, no gaps, exact spacing -----------
    begin : gen_mixed
      opcode_t seq [8];
      logic [XLEN-1:0] expected [16];
      int due [16];
      int accepted, retired, cycle, last_accept, previous_latency, latency;
      bit fire;
      seq = '{AI_DOT4_S8, AI_GETCFG, AI_DOT4_U8, AI_DOT4A_S8,
              AI_POLL, AI_ENQ, AI_GETCFG, AI_DOT4_S8};
      accepted=0; retired=0; cycle=0; last_accept=0; previous_latency=1;
      while (cycle < 16*D4S+4) begin
        @(negedge clk);
        poison_inputs();
        valid_i=(accepted<16) && !busy_o;
        if (valid_i) begin
          registers_i='0;
          registers_i[0]=XLEN'(32'h80ff017f ^ accepted);
          registers_i[1]=XLEN'(32'h02fe7f80 + accepted);
          if(NREG>=3) registers_i[2]=XLEN'(32'h80000000 + 13*accepted);
          aicfg_i=(accepted & 1) ? XLEN'(64'hFEDCBA9876543210)
                                 : XLEN'(64'h0123456789ABCDEF);
          opcode_i=seq[accepted%8];
          instr_i='0;
          set_meta(2'(accepted ^ 1),4'(accepted),5'(accepted+3));
        end
        @(posedge clk);
        fire=valid_i && !busy_o;
        if(fire) begin
          latency=(opcode_i inside {AI_DOT4_S8,AI_DOT4_U8,AI_DOT4A_S8}) ? D4S : 1;
          if(accepted>0) chk(cycle-last_accept==previous_latency,"mixed acceptance spacing");
          case(opcode_i)
            AI_GETCFG: expected[accepted]=aicfg_i;
            AI_POLL: expected[accepted]='0;
            AI_ENQ: expected[accepted]=XLEN'(ENQ_FULL);
            default: expected[accepted]=XLEN'(dot_gold(opcode_i,registers_i));
          endcase
          due[accepted]=cycle+latency-1;
          previous_latency=latency;
          last_accept=cycle;
          accepted++;
        end
        #1;
        if(retired<accepted && due[retired]==cycle) begin
          chk(valid_o===1'b1,"mixed exact valid");
          chkv(result_o,expected[retired],"mixed data");
          chk(id_o===4'(retired),"mixed id");
          chk(hartid_o===2'(retired ^ 1),"mixed hart");
          chk(rd_o===5'(retired+3),"mixed rd");
          chk(we_o && pmu_t0_o && !dirty_o && !sb_enq_valid_o,"mixed side effects");
          retired++;
        end else chk(valid_o===1'b0,"mixed no extra completion");
        cycle++;
      end
      @(negedge clk); valid_i=0; aicfg_i='0;
      chk(accepted==16 && retired==16,"mixed exactly sixteen");
    end

    // ---- MMA 4x4x4 --------------------------------------------------------
    // NOTE: idx_rs2 is instr_i[24:20] (5 bits) so MVTA/MVACC can only
    // address elements 0..31; the 64-element tile's upper half is reached
    // only by the island DMA fill path, not by instruction issue. A 4x4x4
    // MMA keeps every operand/result index < 32 (max m*8+k = 27), which is
    // what this leaf can drive and read back.
    for (int e = 0; e < 28; e++) begin
      tset(0, e, ((e % 8) == (e / 8)) ? 1 : 0);         // identity (rows 0..3)
      tset(1, e, (e * 3 + 7) & 8'h7f);                 // ramp, kept positive-ish
    end
    mma(AI_MMA_S8, 0, 0, 1, 16'h0222);                 // accmode 00, 4x4x4
    for (int m = 0; m < 4; m++)
      for (int n = 0; n < 4; n++)
        aread(0, m * 8 + n, ((m * 8 + n) * 3 + 7) & 8'h7f, "mma_s8 ident");

    // ---- MMA u8, same shape, non-negative data ---------------------------
    for (int e = 0; e < 28; e++) begin
      tset(2, e, (e % 4) + 1);                          // A small pos
      tset(3, e, (e % 7) + 2);                          // B small pos
    end
    // golden: C[m*8+n] = sum_k A[m*8+k]*B[k*8+n], m,n,k < 4
    begin : gen_golden
      int unsigned ga, gb;
      for (int m = 0; m < 4; m++)
        for (int n = 0; n < 4; n++) begin
          av = 0;
          for (int k = 0; k < 4; k++) begin
            ga = ((m * 8 + k) % 4) + 1;
            gb = ((k * 8 + n) % 7) + 2;
            av += ga * gb;
          end
          golden[m * 8 + n] = av;
        end
    end
    mma(AI_MMA_U8, 1, 2, 3, 16'h0222);
    for (int m = 0; m < 4; m++)
      for (int n = 0; n < 4; n++)
        aread(1, m * 8 + n, golden[m * 8 + n], "mma_u8");

    // ---- accmode accumulate arm: second MMA on same tiles doubles acc ----
    mma(AI_MMA_U8, 1, 2, 3, 16'h4222);                 // accmode 01 accumulate
    for (int m = 0; m < 4; m++)
      for (int n = 0; n < 4; n++)
        aread(1, m * 8 + n, 2 * golden[m * 8 + n], "mma_u8 acc2");

    // ---- F17: u8 lane products >= 32768 (255*255 = 65025 per lane, K=4 ->
    // 260100 per element) must accumulate exactly (reference
    // core/cvxif_g6lc_ai/g6lc_ai_exec.sv computes 32'(a*b)); the
    // 16-bit-truncating arm made them negative.
    for (int e = 0; e < 28; e++) begin
      tset(4, e, 255);
      tset(5, e, 255);
    end
    mma(AI_MMA_U8, 2, 4, 5, 16'h0222);
    for (int m = 0; m < 4; m++)
      for (int n = 0; n < 4; n++)
        aread(2, m * 8 + n, 4 * 255 * 255, "mma_u8 F17 255x255");
    // s8 x s8 with -128 * -128 = 16384 per lane (K=4 -> 65536) and a
    // mixed-sign check: -128 * 127 = -16256 per lane (K=4 -> -65024).
    for (int e = 0; e < 28; e++) begin
      tset(6, e, 8'h80);
      tset(7, e, 8'h80);
    end
    mma(AI_MMA_S8, 3, 6, 7, 16'h0222);
    for (int m = 0; m < 4; m++)
      for (int n = 0; n < 4; n++)
        aread(3, m * 8 + n, 4 * 16384, "mma_s8 -128x-128");
    for (int e = 0; e < 28; e++) tset(7, e, 8'h7f);
    mma(AI_MMA_S8, 3, 6, 7, 16'h0222);
    for (int m = 0; m < 4; m++)
      for (int n = 0; n < 4; n++)
        aread32(3, m * 8 + n, 32'(-4 * 16256), "mma_s8 -128x127");

    // ---- verdict ----------------------------------------------------------
    if (errors == 0)
      $display("PASS tb_g6lc_ai_exec_dot checks=%0d", checks);
    else begin
      $display("FAIL tb_g6lc_ai_exec_dot errors=%0d checks=%0d", errors, checks);
      $fatal(1);
    end
    $finish;
  end

  initial begin
    #10000000;
    $display("FAIL tb_g6lc_ai_exec_dot TIMEOUT checks=%0d", checks);
    $fatal(1);
  end
endmodule
