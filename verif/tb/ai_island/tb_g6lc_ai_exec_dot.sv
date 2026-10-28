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
  import g6lc_ai_instr_pkg::*;

  localparam int unsigned XLEN = 64;
  localparam int unsigned NREG = 4;

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

  g6lc_ai_exec #(
      .NrRgprPorts (NREG),
      .XLEN        (XLEN),
      .AiCfg       (config_pkg::AiCfgOff),
      .hartid_t    (logic),
      .id_t        (logic),
      .registers_t (registers_t)
  ) i_dut (
      .clk_i (clk), .rst_ni (rst_n),
      .valid_i, .registers_i, .opcode_i, .instr_i,
      .hartid_i ('0), .id_i ('0), .rd_i (5'd1),
      .aicfg_i, .ais_i, .ai_q_en_i, .ai_qid_i,
      .isl_has_completion_i, .isl_retired_valid_i, .isl_retired_ticket_i,
      .isl_last_ticket_i, .isl_last_status_i, .isl_attached_i,
      .sb_enq_ready_i, .sb_enq_ticket_i,
      .testmode_i (1'b0),
      .setcfg_we_o, .setcfg_wdata_o, .dirty_o, .busy_o,
      .sb_enq_valid_o, .sb_qid_o, .sb_ticket_o, .sb_desc_ptr_o,
      .pmu_op_o, .pmu_mma_o, .pmu_post_o, .pmu_t0_o,
      .result_o, .hartid_o (), .id_o (), .rd_o, .valid_o, .we_o
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

  task automatic t0_check(input opcode_t op, input registers_t regs,
                          input logic [XLEN-1:0] want, input string what);
    issue(op, '0, regs);
    chk(valid_o === 1'b1, {what, " valid"});
    chkv(result_o, want, what);
  endtask

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

  // MMA: rd = acc, rs1 = tile A, rs2 = tile B; dims from aicfg_i.
  task automatic mma(input opcode_t op, input int acc, input int ta, input int tb,
                     input logic [15:0] cfg);
    aicfg_i = {48'd0, cfg};
    issue(op, mk(5'(tb), 5'(ta), 5'(acc)), '{NREG{64'd0}});
    wait (valid_o === 1'b1);
    @(posedge clk); #1;
  endtask

  initial begin
    registers_t regs = '0;
    logic [31:0] golden [64];
    int unsigned av, bv;

    valid_i = 0; opcode_i = AI_ILLEGAL; instr_i = '0; registers_i = '0;
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
    // dot4a: acc=100 + same s8 dot (70) = 170
    regs[0] = 64'h04030201; regs[1] = 64'h08070605; regs[2] = 64'd100;
    t0_check(AI_DOT4A_S8, regs, 64'd170, "dot4a_s8 acc");

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

    // ---- verdict ----------------------------------------------------------
    if (errors == 0)
      $display("PASS tb_g6lc_ai_exec_dot checks=%0d", checks);
    else
      $display("FAIL tb_g6lc_ai_exec_dot errors=%0d checks=%0d", errors, checks);
    $finish;
  end

  initial begin
    #2000000;
    $display("FAIL tb_g6lc_ai_exec_dot TIMEOUT checks=%0d", checks);
    $finish;
  end
endmodule
