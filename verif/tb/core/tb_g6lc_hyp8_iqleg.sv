// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 r68 leaf -- g6lc_iq_legal occupant identity.
//
// The bench stands in for the banks: it drives the per-entry info arrays
// (live valid/tid/class, the NEXT-state tid, the bank-local class
// frontiers) with the g6lc_iq_bank allocation timing -- a slot accepted
// at cycle A appears in the next-state tid at A+1 and in the live record
// at A+2 -- and samples legal_o each cycle. Every check is a contract
// sentence over the closed tuple {live, tid, class, commit_ptr, frontier,
// unresolved mask}; no instruction encoding, PC or firmware symbol.
//
//   L1 a head-only occupant (AMO/LR/SC, system CSR, CVXIF) is never legal
//      while its tid differs from the commit head -- in particular not in
//      its first live cycle, whatever record the slot held before;
//   L2 a head-only occupant at the head is legal in its second live cycle
//      (the registered facts already belong to it) and stays legal;
//   L3 a fresh load behind an older unresolved store is not legal in any
//      cycle before the store resolves, and is legal two cycles after;
//   L4 two same-group stores: the younger is never legal before the
//      older; the older is legal once the frontier has seen both;
//   L5 a slot whose stale record was a head-only op at the head does not
//      make a new non-head head-only occupant legal (the r62b shape).
//
// Negative control: HYP8_EXTRA_DEFINES=G6LC_MUT_IQLEG_STALE_OCCUPANT
// restores the pre-r68 legality (facts from the live tid, no liveness
// gate); L1 must fail by name (the first-live-cycle leak) and L4's
// younger-store check must fail.
//
// Stimulus is driven on the clock-low phase and outputs sampled after
// the posedge (one sample point per tick, the leaf-bench discipline).

module tb_g6lc_hyp8_iqleg;
  import g6lc_core_pkg::*;

  function automatic config_pkg::g6lc_cfg_t configuration();
    config_pkg::g6lc_cfg_t c = config_pkg::g6lc_cfg_empty;
    c.XLEN = 64; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 64; c.IS_XLEN64 = 1;
    c.NrHarts = 1;
    c.NrIssuePorts = 2; c.NrCommitPorts = 2; c.NrWbPorts = 2;
    c.NR_SB_ENTRIES = 32; c.TRANS_ID_BITS = 5;
    c.OoOEn = 1; c.SpeculativeSb = 1; c.SuperscalarEn = 1;
    c.RVS = 1; c.RVU = 1; c.RVA = 1; c.MmuPresent = 1;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = configuration();

  localparam int unsigned BANKS = 2, ENTRIES = 4, TID_W = 5, HID_W = 1, NH = 1;
  localparam int unsigned C_LD = 0, C_ST = 1, C_CSR = 2, C_CSYS = 3,
                          C_AMO = 4, C_CVXI = 5, C_FP = 6;
  localparam logic [6:0] CLS_NONE = 7'b0000000;
  localparam logic [6:0] CLS_LD   = 7'b0000001;
  localparam logic [6:0] CLS_AMO  = 7'b0010010;   // store class + AMO (LR/SC/AMO)
  localparam logic [6:0] CLS_ST   = 7'b0000010;

  logic clk = 1'b0, rst_n = 1'b0, flush = 1'b0;
  logic [BANKS-1:0][ENTRIES-1:0]            info_v;
  logic [BANKS-1:0][ENTRIES-1:0][TID_W-1:0] info_tid, info_tid_d;
  logic [BANKS-1:0][ENTRIES-1:0][HID_W-1:0] info_hart;
  logic [BANKS-1:0][ENTRIES-1:0][6:0]       info_cls;
  logic [BANKS-1:0][ENTRIES-1:0]            info_bypass;
  logic [BANKS-1:0]                         csr_oldest_v, st_oldest_v;
  logic [BANKS-1:0][TID_W-1:0]              csr_oldest_tid, st_oldest_tid;
  logic [TID_W-1:0]                         commit_ptr;
  logic [C.NR_SB_ENTRIES-1:0]               st_unres;
  logic [NH-1:0][C.NR_SB_ENTRIES-1:0]       st_hart_mask;
  logic                                     mem_stall;
  logic [BANKS-1:0][ENTRIES-1:0]            legal;

  g6lc_iq_legal #(
      .G6LCCfg(C), .BANKS(BANKS), .ENTRIES(ENTRIES), .TID_W(TID_W),
      .HID_W(HID_W), .NH(NH)
  ) dut (
      .clk_i(clk), .rst_ni(rst_n), .flush_i(flush),
      .info_v_i(info_v), .info_tid_i(info_tid), .info_tid_d_i(info_tid_d),
      .info_hart_i(info_hart), .info_cls_i(info_cls), .info_bypass_i(info_bypass),
      .csr_oldest_v_i(csr_oldest_v), .csr_oldest_tid_i(csr_oldest_tid),
      .st_oldest_v_i(st_oldest_v), .st_oldest_tid_i(st_oldest_tid),
      .commit_ptr_i(commit_ptr), .st_unresolved_mask_i(st_unres),
      .st_hart_mask_i(st_hart_mask), .mem_stall_i(mem_stall),
      .legal_o(legal)
  );

  // ----------------------------------------------------------------------
  // Bank stand-in: records plus the pend stage. `rec` is the live view
  // (info_*), `pend` is what lands at the next edge (info_tid_d).
  // ----------------------------------------------------------------------
  typedef struct packed {
    logic             v;
    logic [TID_W-1:0] tid;
    logic [6:0]       cls;
  } rec_t;
  rec_t [BANKS-1:0][ENTRIES-1:0] rec;      // live record
  rec_t [BANKS-1:0][ENTRIES-1:0] pend;     // lands next edge when pend.v
  int unsigned checked = 0, failed = 0;

  // bank-local store/CSR frontier = oldest live same-class entry; the
  // bench uses allocation order as age (tids increase with age here).
  always_comb begin
    for (int unsigned b = 0; b < BANKS; b++) begin
      automatic logic sv = 0, cv = 0;
      automatic logic [TID_W-1:0] stid = '0, ctid = '0;
      for (int unsigned e = 0; e < ENTRIES; e++) begin
        info_v[b][e]      = rec[b][e].v;
        info_tid[b][e]    = rec[b][e].tid;
        info_cls[b][e]    = rec[b][e].cls;
        info_hart[b][e]   = '0;
        info_bypass[b][e] = 1'b0;
        // next-state tid: the pend record if one lands, else the live tid
        info_tid_d[b][e]  = pend[b][e].v ? pend[b][e].tid : rec[b][e].tid;
        if (rec[b][e].v && rec[b][e].cls[C_ST] &&
            (!sv || (rec[b][e].tid - commit_ptr) < (stid - commit_ptr))) begin
          sv = 1; stid = rec[b][e].tid;
        end
        if (rec[b][e].v && rec[b][e].cls[C_CSR] &&
            (!cv || (rec[b][e].tid - commit_ptr) < (ctid - commit_ptr))) begin
          cv = 1; ctid = rec[b][e].tid;
        end
      end
      st_oldest_v[b] = sv;  st_oldest_tid[b] = stid;
      csr_oldest_v[b] = cv; csr_oldest_tid[b] = ctid;
    end
  end

  // pend lands into the live record at the edge
  always_ff @(posedge clk) begin
    for (int unsigned b = 0; b < BANKS; b++)
      for (int unsigned e = 0; e < ENTRIES; e++)
        if (pend[b][e].v) begin
          rec[b][e]  <= pend[b][e];
          pend[b][e] <= '0;
        end
  end

  task automatic tick();
    #5 clk = 1'b1; #5 clk = 1'b0;
  endtask

  // alloc at this cycle: pend is visible to info_tid_d from the next
  // low phase (the bank's pend_slot_q), live two edges later.
  task automatic alloc(input int b, input int e, input logic [TID_W-1:0] tid,
                       input logic [6:0] cls);
    tick();                       // A: accept (bank scans free_mask)
    pend[b][e] = '{v: 1'b1, tid: tid, cls: cls};   // A+1: pend_slot_q
  endtask

  task automatic free(input int b, input int e);
    rec[b][e].v = 1'b0;           // stale tid/cls stay, as in the bank
  endtask

  task automatic expect_legal(input string name, input int b, input int e,
                              input logic want);
    checked++;
    if (legal[b][e] !== want) begin
      failed++;
      $display("FAIL %s: legal[%0d][%0d]=%b want %b (tid=%0d cls=%b ptr=%0d)",
               name, b, e, legal[b][e], want, rec[b][e].tid, rec[b][e].cls,
               commit_ptr);
    end
  endtask

  initial begin
    rec = '0; pend = '0;
    commit_ptr = '0; st_unres = '0; st_hart_mask = '1; mem_stall = 1'b0;
    repeat (2) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    // -------------------------------------------------------------- L1
    // Reset-state slots hold cls=0/tid=0. Head is tid 0 (a load, bank 0
    // entry 0, allocated first). A head-only AMO tid 3 lands in bank 1
    // entry 0 whose stale record is the reset record (non-ordered class,
    // tid 0 == commit_ptr): the leak shape of every post-reset / post-
    // flush slot.
    alloc(0, 0, 5'd0, CLS_LD);
    alloc(1, 0, 5'd3, CLS_AMO);
    tick();                       // AMO live from here (first live cycle)
    expect_legal("L1 first-live-cycle head-only non-head", 1, 0, 1'b0);
    tick();
    expect_legal("L1 second-live-cycle head-only non-head", 1, 0, 1'b0);
    repeat (3) tick();
    expect_legal("L1 steady head-only non-head", 1, 0, 1'b0);

    // -------------------------------------------------------------- L2
    // The head retires; commit_ptr reaches tid 3: legal the cycle after
    // the registered head fact (not before).
    free(0, 0);
    commit_ptr = 5'd3;
    tick();                       // at_head_d computed this cycle
    tick();                       // legal_d computed from at_head_q
    expect_legal("L2 head-only at head legal after facts", 1, 0, 1'b1);
    tick();
    expect_legal("L2 head-only at head stays legal", 1, 0, 1'b1);
    // and a second head-only op allocated now (tid 4, bank 0 entry 1,
    // stale record = reset record) is NOT legal while tid 3 is the head
    alloc(0, 1, 5'd4, CLS_AMO);
    tick();
    expect_legal("L1b younger head-only first live cycle", 0, 1, 1'b0);
    tick();
    expect_legal("L1b younger head-only second live cycle", 0, 1, 1'b0);
    // tid 3 issues (slot freed), head moves to tid 4
    free(1, 0);
    commit_ptr = 5'd4;
    tick(); tick();
    expect_legal("L2b second head-only legal at head", 0, 1, 1'b1);

    // -------------------------------------------------------------- L5
    // Slot (1,0) still holds the stale record of tid 3 (head-only, was at
    // head). A new head-only occupant tid 9 lands there while tid 4 is
    // the head: never legal.
    alloc(1, 0, 5'd9, CLS_AMO);
    tick();
    expect_legal("L5 stale-head-only slot, new non-head occupant", 1, 0, 1'b0);
    tick();
    expect_legal("L5 stale-head-only slot, second cycle", 1, 0, 1'b0);
    free(0, 1); free(1, 0);
    commit_ptr = 5'd10;
    repeat (3) tick();

    // -------------------------------------------------------------- L3
    // Store tid 10 unresolved (in the scoreboard mask), a fresh load tid
    // 11 lands in bank 0 entry 2 (stale record: reset, non-ordered).
    st_unres[10] = 1'b1;
    alloc(0, 2, 5'd11, CLS_LD);
    tick();
    expect_legal("L3 fresh load behind unresolved store, first cycle", 0, 2, 1'b0);
    tick();
    expect_legal("L3 fresh load behind unresolved store, second cycle", 0, 2, 1'b0);
    repeat (2) tick();
    expect_legal("L3 load still waits", 0, 2, 1'b0);
    st_unres[10] = 1'b0;          // store resolves
    tick();                       // unres_d sees it
    tick();                       // legal_d sees unres_q
    expect_legal("L3 load legal after resolve", 0, 2, 1'b1);
    free(0, 2);
    repeat (2) tick();

    // -------------------------------------------------------------- L4
    // Two stores of one dispatch group: older tid 12 (bank 0 entry 3),
    // younger tid 13 (bank 1 entry 1), both land at the same edge.
    tick();
    pend[0][3] = '{v: 1'b1, tid: 5'd12, cls: CLS_ST};
    pend[1][1] = '{v: 1'b1, tid: 5'd13, cls: CLS_ST};
    tick();                       // both live (first live cycle)
    expect_legal("L4 older store first live cycle", 0, 3, 1'b0);
    expect_legal("L4 younger store first live cycle", 1, 1, 1'b0);
    tick();                       // warm, frontier formed from both
    expect_legal("L4 younger store never before older (warm)", 1, 1, 1'b0);
    tick();
    expect_legal("L4 older store legal once frontier seen", 0, 3, 1'b1);
    expect_legal("L4 younger store waits for older", 1, 1, 1'b0);
    free(0, 3);                   // older store issues
    tick(); tick(); tick();
    expect_legal("L4 younger store legal after older left", 1, 1, 1'b1);

    // -------------------------------------------------------------- flush
    flush = 1'b1; tick(); flush = 1'b0;
    rec = '0; pend = '0; commit_ptr = '0;
    alloc(0, 0, 5'd0, CLS_AMO);   // head-only AT the head after a flush
    tick();
    expect_legal("F head-only at head, first live cycle (facts pending)", 0, 0, 1'b0);
    tick();
    // an AMO is store-class as well (fu == STORE): the T24 frontier warm
    // gate holds it one more cycle than a pure head-only op would wait
    expect_legal("F head-only+store at head, second live cycle (frontier warm)", 0, 0, 1'b0);
    tick();
    expect_legal("F head-only at head after facts + frontier", 0, 0, 1'b1);

    if (failed == 0) $display("HYP8_IQLEG_PASS checked=%0d", checked);
    else $display("HYP8_IQLEG_FAIL failed=%0d checked=%0d", failed, checked);
    $finish;
  end
endmodule
