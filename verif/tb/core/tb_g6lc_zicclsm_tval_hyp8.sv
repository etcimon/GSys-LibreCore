// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 g6lc_zicclsm leaf: RISC-V Priv §3.1.16 / Zicclsm Beat-0 vs
// Beat-1 load exception tval & cross-word assembly verification.
//
// Scenarios:
//   S1. Cross-word LD at 0x8000_1005 faults on Beat 0 (FU returns rounded
//       tval=0x8000_1000) -> g6lc_zicclsm restores exact tval=0x8000_1005
//       across B0_WAIT, B0_ACTIVE, and IDLE.
//   S2. Page-crossing LD at 0x8000_1FFD succeeds on Beat 0 (0x8000_1FF8) and
//       faults on Beat 1 (0x8000_2000) -> preserves Beat-1 tval=0x8000_2000.
//   S3. Normal cross-word LD at 0x8000_1005 -> exact little-endian 64-bit
//       re-assembly across Beat 0 + Beat 1.
//
// Review mutation (must fail):
//   -DG6LC_MUT_ZICCLSM_B0_ALIGNED_TVAL -> S1 fails S1_B0_WAIT_EXACT_TVAL
//
// PASS token: PASS tb_g6lc_zicclsm_tval_hyp8
`include "g6lc_core_types.svh"

module tb_g6lc_zicclsm_tval_hyp8;
  import g6lc_core_pkg::*;

  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned HID_W = $clog2(C.NrHarts > 1 ? C.NrHarts : 2);

  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef struct packed {
    logic                       valid;
    logic [C.VLEN-1:0]          vaddr;
    logic [31:0]                tinst;
    logic                       hs_ld_st_inst;
    logic                       hlvx_inst;
    logic                       overflow;
    logic                       g_overflow;
    logic [C.XLEN-1:0]          data;
    logic [C.XLEN-1:0]          data_cmp;
    logic [C.XLEN-1:0]          data_hi;
    logic [C.XLEN-1:0]          data_cmp_hi;
    logic [(C.XLEN/8)-1:0]      be;
    fu_t                        fu;
    fu_op                       operation;
    logic [C.TRANS_ID_BITS-1:0] trans_id;
    logic [HID_W-1:0]           hart;
    logic                       is_speculative_load;
    logic                       is_speculative_load_miss;
    logic [2:0]                 data_prot;
  } lsu_ctrl_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_zicclsm_tval_hyp8");
    end
  endtask

  lsu_ctrl_t                  ctrl_i = '0, ctrl_o;
  logic                       pop_ld_fu = 0, pop_st_fu = 0, pop_ld_byp, pop_st_byp;
  logic                       ld_valid_fu = 0, ld_valid_o;
  logic [C.XLEN-1:0]          ld_res_fu = '0, ld_res_o;
  exception_t                 ld_ex_fu = '0, ld_ex_o;
  logic [C.TRANS_ID_BITS-1:0] ld_tid_fu = '0, ld_tid_o;

  g6lc_zicclsm #(
      .G6LCCfg    (C),
      .lsu_ctrl_t (lsu_ctrl_t),
      .exception_t(exception_t)
  ) dut (
      .clk_i            (clk),
      .rst_ni           (rst_n),
      .flush_i          (1'b0),
      .ctrl_i           (ctrl_i),
      .ctrl_o           (ctrl_o),
      .pop_ld_fu_i      (pop_ld_fu),
      .pop_st_fu_i      (pop_st_fu),
      .pop_ld_byp_o     (pop_ld_byp),
      .pop_st_byp_o     (pop_st_byp),
      .ld_valid_fu_i    (ld_valid_fu),
      .ld_result_fu_i   (ld_res_fu),
      .ld_ex_fu_i       (ld_ex_fu),
      .ld_tid_fu_i      (ld_tid_fu),
      .ld_valid_o       (ld_valid_o),
      .ld_result_o      (ld_res_o),
      .ld_ex_o          (ld_ex_o),
      .ld_tid_o         (ld_tid_o),
      .st_valid_fu_i    (1'b0),
      .st_result_fu_i   ('0),
      .st_ex_fu_i       ('0),
      .st_tid_fu_i      ('0),
      .st_valid_o       (),
      .st_result_o      (),
      .st_ex_o          (),
      .st_tid_o         (),
      .ld_head_checked_i(1'b1),
      .lu_replay_fu_i   (1'b0),
      .ld_replay_o      (),
      .ld_replay_id_o   ()
  );

  function automatic lsu_ctrl_t mk_ld(input logic [63:0] va, input logic [C.TRANS_ID_BITS-1:0] tid);
    lsu_ctrl_t c = '0;
    c.valid     = 1'b1;
    c.vaddr     = va;
    c.fu        = LOAD;
    c.operation = LD;
    c.trans_id  = tid;
    return c;
  endfunction

  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // ---- S1a: Beat-0 fault in B0_WAIT -> exact unrounded tval 0x8000_1005 ----
    ctrl_i    = mk_ld(64'h0000_0000_8000_1005, 'd3);
    pop_ld_fu = 1'b1;  // accept beat 0 -> moves IDLE -> B0_WAIT
    #1;
    check(ctrl_o.vaddr === 64'h0000_0000_8000_1000, "S1A_B0_ROUNDED_VA");
    tick();
    pop_ld_fu   = 1'b0;
    ld_valid_fu = 1'b1;
    ld_tid_fu   = 'd3;
    ld_ex_fu    = '{valid: 1'b1, cause: riscv::LOAD_PAGE_FAULT,
                    tval: 64'h0000_0000_8000_1000, default: '0};
    #1;
    check(ld_valid_o === 1'b1 && ld_ex_o.valid === 1'b1, "S1A_B0_WAIT_EX_VALID");
    check(ld_ex_o.tval === 64'h0000_0000_8000_1005, "S1_B0_WAIT_EXACT_TVAL");
    check(pop_ld_byp === 1'b1, "S1A_POP_BYP");
    tick();
    ld_valid_fu = 1'b0; ld_ex_fu = '0; ctrl_i = '0;
    tick();

    // ---- S1b: Beat-0 immediate fault in IDLE -> exact tval 0x8000_1006 ----
    ctrl_i      = mk_ld(64'h0000_0000_8000_1006, 'd4);
    ld_valid_fu = 1'b1;
    ld_tid_fu   = 'd4;
    ld_ex_fu    = '{valid: 1'b1, cause: riscv::LD_ACCESS_FAULT,
                    tval: 64'h0000_0000_8000_1000, default: '0};
    #1;
    check(ld_valid_o === 1'b1 && ld_ex_o.tval === 64'h0000_0000_8000_1006, "S1B_IDLE_EXACT_TVAL");
    tick();
    ld_valid_fu = 1'b0; ld_ex_fu = '0; ctrl_i = '0;
    tick();

    // ---- S2: Page-crossing LD at 0x8000_1FFD -> Beat 0 OK, Beat 1 faults at 0x8000_2000 ----
    ctrl_i    = mk_ld(64'h0000_0000_8000_1FFD, 'd5);
    pop_ld_fu = 1'b1;
    tick();
    pop_ld_fu   = 1'b0;
    ld_valid_fu = 1'b1;
    ld_tid_fu   = 'd5;
    ld_res_fu   = 64'hAABB_CC00_0000_0000;  // Beat 0 succeeds
    tick();
    ld_valid_fu = 1'b0;
    pop_ld_fu   = 1'b1;  // accept beat 1 (vaddr = 0x8000_2000)
    #1;
    check(ctrl_o.vaddr === 64'h0000_0000_8000_2000, "S2_B1_PAGE_VA");
    tick();
    pop_ld_fu   = 1'b0;
    ld_valid_fu = 1'b1;
    ld_tid_fu   = 'd5;
    ld_ex_fu    = '{valid: 1'b1, cause: riscv::LOAD_PAGE_FAULT,
                    tval: 64'h0000_0000_8000_2000, default: '0};
    #1;
    check(ld_valid_o === 1'b1 && ld_ex_o.tval === 64'h0000_0000_8000_2000, "S2_B1_PRESERVES_PAGE_TVAL");
    tick();
    ld_valid_fu = 1'b0; ld_ex_fu = '0; ctrl_i = '0;
    tick();

    // ---- S3: Normal cross-word LD at 0x8000_1005 -> exact assembled 64-bit value ----
    // off=5 -> n0=3 bytes from beat0[63:40] = 33_22_11, n1=5 bytes from beat1[39:0] = 88_77_66_55_44
    ctrl_i    = mk_ld(64'h0000_0000_8000_1005, 'd6);
    pop_ld_fu = 1'b1;
    tick();
    pop_ld_fu   = 1'b0;
    ld_valid_fu = 1'b1; ld_tid_fu = 'd6; ld_res_fu = 64'h3322_1100_0000_0000;
    tick();
    ld_valid_fu = 1'b0; pop_ld_fu = 1'b1;
    tick();
    pop_ld_fu   = 1'b0;
    ld_valid_fu = 1'b1; ld_tid_fu = 'd6; ld_res_fu = 64'h0000_0088_7766_5544;
    tick();
    ld_valid_fu = 1'b0; ctrl_i = '0;
    #1;
    check(ld_valid_o === 1'b1 && ld_tid_o === 'd6 && ld_ex_o.valid === 1'b0, "S3_ASSEMBLED_VALID");
    check(ld_res_o === 64'h8877_6655_4433_2211, "S3_ASSEMBLED_DATA");

    $display("PASS tb_g6lc_zicclsm_tval_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
