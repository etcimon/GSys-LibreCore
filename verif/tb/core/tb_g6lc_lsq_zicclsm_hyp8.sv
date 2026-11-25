// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 g6lc_lsq + g6lc_lsq_cam_bank leaf verifying Bugs #1-#3 under
// hyp8-mc (COH_OOO, RVZicclsm=1):
//   S1 (Bug #1): Older cross-word SD (0x8000_1005, size=3, bytes 5..12) vs
//                younger LD (0x8000_1008, size=3, bytes 8..15) -> phys_replay_o!
//   S2 (Bug #2): Older aligned SD (0x8000_2008, size=3) vs younger cross-word
//                LD (0x8000_2005, size=3, bytes 5..12) -> phys_replay_o!
//   S3 (Bug #3): Speculative cross-cache-line LD (0x8000_003D, size=3, lines
//                0x0000 & 0x0040) + peer COH_OOO mod_valid_i on line 0x8000_0040
//                -> phys_replay_o!
//   S4 (Clean):  Disjoint same-word SW (0x8000_3000, size=2) vs LW (0x8000_3004,
//                size=2) -> ZERO false replay!
//
// Review mutations (each must fail):
//   -DG6LC_MUT_LSQ_NO_ZICCLSM_CROSSWORD -> fails S1_CROSSWORD_ST_LD_REPLAY
//   -DG6LC_MUT_LSQ_NO_CROSSLINE_MOD     -> fails S3_CROSSLINE_MOD_REPLAY
//
// PASS token: PASS tb_g6lc_lsq_zicclsm_hyp8
module tb_g6lc_lsq_zicclsm_hyp8;
  import g6lc_core_pkg::*;
  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned NA = 2;
  localparam int unsigned NU = 2;
  localparam int unsigned IDW = C.TRANS_ID_BITS;
  localparam int unsigned NSB = C.NR_SB_ENTRIES;
  localparam int unsigned NWB = C.NrWbPorts;
  localparam int unsigned NCP = C.NrCommitPorts;
  localparam int unsigned HIDW = $clog2(C.NrHarts > 1 ? C.NrHarts : 2);

  logic clk = 0, rst_n = 0, flush = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_lsq_zicclsm_hyp8");
    end
  endtask

  logic [NSB-1:0] cancelled = '0, sb_live = '0;
  logic [NA-1:0] ld_alloc = '0, st_alloc = '0;
  logic [NA-1:0][IDW-1:0] alloc_id = '0;
  logic [NA-1:0][HIDW-1:0] alloc_hart = '0;
  logic [NA-1:0][C.VLEN-1:0] alloc_pc = '0;
  logic [NU-1:0] addr_v = '0, addr_is_st = '0, st_data_v = '0;
  logic [NU-1:0][IDW-1:0] addr_id = '0, st_data_id = '0;
  logic [NU-1:0][C.PLEN-1:0] addr_i = '0;
  logic [NU-1:0][1:0] addr_sz = '0;
  logic [NU-1:0][C.XLEN-1:0] st_data = '0;
  logic [1:0] phys_v = '0, mod_v = '0;
  logic [1:0][C.PLEN-1:0] phys_a = '0, mod_a = '0;
  logic [1:0][IDW-1:0] phys_id = '0;
  logic [1:0][HIDW-1:0] phys_h = '0;
  logic [1:0][1:0] phys_sz = '0;
  logic [IDW-1:0] cmt_ptr = '0;
  logic [NSB-1:0] phys_pend, phys_replay, ld_checked;
  logic mem_viol, replay_v;
  logic [IDW-1:0] mem_viol_id, replay_tid;

  g6lc_lsq #(
      .G6LCCfg   (C),
      .LD_ENTRIES(8),
      .ST_ENTRIES(8),
      .NR_ALLOC  (NA),
      .NR_UPDATE (NU)
  ) dut (
      .clk_i               (clk),
      .rst_ni              (rst_n),
      .flush_i             (flush),
      .cancelled_mask_i    (cancelled),
      .sb_live_i           (sb_live),
      .ld_alloc_i          (ld_alloc),
      .st_alloc_i          (st_alloc),
      .alloc_id_i          (alloc_id),
      .alloc_hart_i        (alloc_hart),
      .alloc_pc_i          (alloc_pc),
      .ld_full_o           (),
      .st_full_o           (),
      .ld_free_o           (),
      .st_free_o           (),
      .addr_valid_i        (addr_v),
      .addr_id_i           (addr_id),
      .addr_i              (addr_i),
      .addr_is_st_i        (addr_is_st),
      .addr_size_i         (addr_sz),
      .st_data_valid_i     (st_data_v),
      .st_data_id_i        (st_data_id),
      .st_data_i           (st_data),
      .complete_valid_i    ({NWB{1'b0}}),
      .complete_id_i       ('0),
      .complete_is_st_i    ({NWB{1'b0}}),
      .commit_st_i         ({NCP{1'b0}}),
      .commit_id_i         ('0),
      .commit_ptr_i        (cmt_ptr),
      .ld_query_i          (1'b0),
      .ld_query_addr_i     ('0),
      .ld_query_size_i     (2'd0),
      .ld_query_id_i       ('0),
      .ld_query_hart_i     ('0),
      .st_live_mask_o      (),
      .st_unresolved_mask_o(),
      .st_hart_mask_o      (),
      .store_pending_o     (),
      .stl_forward_o       (),
      .stl_data_o          (),
      .stl_stall_o         (),
      .lsq_busy_o          (),
      .mem_violation_o     (mem_viol),
      .mem_violation_id_o  (mem_viol_id),
      .mem_violation_pc_o  (),
      .phys_valid_i        (phys_v),
      .phys_addr_i         (phys_a),
      .phys_id_i           (phys_id),
      .phys_hart_i         (phys_h),
      .phys_size_i         (phys_sz),
      .commit_ld_i         ({NCP{1'b0}}),
      .mod_valid_i         (mod_v),
      .mod_addr_i          (mod_a),
      .phys_pending_o      (phys_pend),
      .phys_replay_o       (phys_replay),
      .ld_checked_o        (ld_checked),
      .replay_valid_o      (replay_v),
      .replay_tid_o        (replay_tid)
  );

  task automatic reset_lsq();
    flush = 1'b1; cancelled = '0;
    ld_alloc = '0; st_alloc = '0; phys_v = '0; mod_v = '0; addr_v = '0;
    tick();
    flush = 1'b0; sb_live = '0;
    tick();
  endtask

  bit saw_rep;
  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // ---- S1 (Bug #1): Older cross-word SD (0x8000_1005, bytes 5..12, tid=1)
    //                   vs younger LD (0x8000_1008, bytes 8..15, tid=2) ----
    reset_lsq();
    cmt_ptr = IDW'(1);
    sb_live[1] = 1'b1; sb_live[2] = 1'b1;
    st_alloc = 2'b01; ld_alloc = 2'b10;
    alloc_id[0] = IDW'(1); alloc_id[1] = IDW'(2);
    alloc_pc[1] = 64'h8000_0100;
    tick();
    st_alloc = '0; ld_alloc = '0;
    // Younger load resolves first at 0x8000_1008 (size=3 -> 8B)
    phys_v = 2'b01; phys_id[0] = IDW'(2); phys_a[0] = C.PLEN'(64'h8000_1008); phys_sz[0] = 2'd3;
    tick();
    phys_v = '0;
    tick();
    // Older cross-word store resolves at 0x8000_1005 (size=3 -> bytes 5..12, overlaps 8..12!)
    phys_v = 2'b10; phys_id[1] = IDW'(1); phys_a[1] = C.PLEN'(64'h8000_1005); phys_sz[1] = 2'd3;
    saw_rep = 1'b0;
    for (int cyc = 0; cyc < 5; cyc++) begin
      tick();
      phys_v = '0;
      if (phys_replay[2]) saw_rep = 1'b1;
    end
    check(saw_rep, "S1_CROSSWORD_ST_LD_REPLAY");

    // ---- S2 (Bug #2): Older aligned SD (0x8000_2008, tid=3) vs younger
    //                   cross-word LD (0x8000_2005, bytes 5..12, tid=4) ----
    reset_lsq();
    cmt_ptr = IDW'(3);
    sb_live[3] = 1'b1; sb_live[4] = 1'b1;
    st_alloc = 2'b01; ld_alloc = 2'b10;
    alloc_id[0] = IDW'(3); alloc_id[1] = IDW'(4);
    tick();
    st_alloc = '0; ld_alloc = '0;
    phys_v = 2'b01; phys_id[0] = IDW'(4); phys_a[0] = C.PLEN'(64'h8000_2005); phys_sz[0] = 2'd3;
    tick();
    phys_v = '0;
    tick();
    phys_v = 2'b10; phys_id[1] = IDW'(3); phys_a[1] = C.PLEN'(64'h8000_2008); phys_sz[1] = 2'd3;
    saw_rep = 1'b0;
    for (int cyc = 0; cyc < 5; cyc++) begin
      tick();
      phys_v = '0;
      if (phys_replay[4]) saw_rep = 1'b1;
    end
    check(saw_rep, "S2_CROSSWORD_LD_ST_REPLAY");

    // ---- S3 (Bug #3): Speculative cross-cache-line LD (0x8000_003D, size=3,
    //                   spans lines 0x0000 and 0x0040, tid=6) + peer COH_OOO
    //                   invalidation mod_valid_i on second line 0x8000_0040 ----
    reset_lsq();
    cmt_ptr = IDW'(6);
    sb_live[6] = 1'b1;
    ld_alloc = 2'b01; alloc_id[0] = IDW'(6);
    tick();
    ld_alloc = '0;
    phys_v = 2'b01; phys_id[0] = IDW'(6); phys_a[0] = C.PLEN'(64'h8000_003D); phys_sz[0] = 2'd3;
    tick();
    phys_v = '0;
    tick();
    mod_v = 2'b01; mod_a[0] = C.PLEN'(64'h8000_0040);
    saw_rep = 1'b0;
    for (int cyc = 0; cyc < 5; cyc++) begin
      tick();
      mod_v = '0;
      if (phys_replay[6]) saw_rep = 1'b1;
    end
    check(saw_rep, "S3_CROSSLINE_MOD_REPLAY");

    // ---- S4 (Negative control): Disjoint SW (0x8000_3000, size=2) vs LW (0x8000_3004, size=2) ----
    reset_lsq();
    cmt_ptr = IDW'(8);
    sb_live[8] = 1'b1; sb_live[9] = 1'b1;
    st_alloc = 2'b01; ld_alloc = 2'b10;
    alloc_id[0] = IDW'(8); alloc_id[1] = IDW'(9);
    tick();
    st_alloc = '0; ld_alloc = '0;
    phys_v = 2'b01; phys_id[0] = IDW'(9); phys_a[0] = C.PLEN'(64'h8000_3004); phys_sz[0] = 2'd2;
    tick();
    phys_v = '0;
    tick();
    phys_v = 2'b10; phys_id[1] = IDW'(8); phys_a[1] = C.PLEN'(64'h8000_3000); phys_sz[1] = 2'd2;
    saw_rep = 1'b0;
    for (int cyc = 0; cyc < 5; cyc++) begin
      tick();
      phys_v = '0;
      if (phys_replay[9]) saw_rep = 1'b1;
    end
    check(!saw_rep, "S4_DISJOINT_NO_FALSE_REPLAY");

    $display("PASS tb_g6lc_lsq_zicclsm_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
