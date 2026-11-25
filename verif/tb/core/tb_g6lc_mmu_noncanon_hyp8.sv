// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 MMU + PMP non-canonical VA & exception-priority leaf:
// Instantiates real g6lc_mmu (Hyp8, TlbStages=3, UseSharedTlb=0, Sv39) wired
// into real pmp_data_if (DATA_VERDICT_STAGES=0) with S-mode PMP denying PA 0.
//
// Proves:
//   1. Non-canonical Sv39 fetch (0x6a09e667bb67ae80, exact tracedb r127m VA)
//      raises immediate INSTR_PAGE_FAULT through MMU+PMP with ZERO PTW walks.
//   2. Non-canonical Sv39 load (0x6a09e667bb67ae80) & store
//      (0x0000_0040_0000_1000) raise LOAD_PAGE_FAULT / STORE_PAGE_FAULT through
//      MMU+PMP (not overwritten by PMP access fault) with ZERO PTW walks.
//   3. Canonical Sv39 fetch & load still walk the page table and translate.
//
// Review mutations (must fail):
//   -DG6LC_MUT_MMU_NONCANON_WALK -> non-canonical fetch/LSU launches PTW walk
//                                   and stalls fetch_valid / fails NC_*_NO_PTW
//   -DG6LC_MUT_PMP_OVERWRITE_EX  -> PMP overwrites LOAD/STORE_PAGE_FAULT with
//                                   LD/ST_ACCESS_FAULT
//
// PASS token: PASS tb_g6lc_mmu_noncanon_hyp8
`include "g6lc_core_types.svh"

module tb_g6lc_mmu_noncanon_hyp8;
  import g6lc_core_pkg::*;

  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;
  localparam int NPE = C.NrPMPEntries;

  typedef `G6LC_EXCEPTION_T(C) exception_t;
  typedef struct packed {
    logic                    fetch_valid;
    logic [C.PLEN-1:0]       fetch_paddr;
    exception_t              fetch_exception;
  } icache_areq_t;
  typedef struct packed {
    logic                    fetch_req;
    logic [C.VLEN-1:0]       fetch_vaddr;
  } icache_arsp_t;
  typedef struct packed {
    logic [C.DCACHE_INDEX_WIDTH-1:0] address_index;
    logic [C.DCACHE_TAG_WIDTH-1:0]   address_tag;
    logic [C.XLEN-1:0]               data_wdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_wuser;
    logic                            data_req;
    logic                            data_we;
    logic [(C.XLEN/8)-1:0]           data_be;
    logic [1:0]                      data_size;
    logic [C.DcacheIdWidth-1:0]      data_id;
    logic                            kill_req;
    logic                            tag_valid;
    logic [7:0]                      cbo_op;
    logic [2:0]                      data_prot;
  } dcache_req_i_t;
  typedef struct packed {
    logic                            data_gnt;
    logic                            data_rvalid;
    logic [C.DcacheIdWidth-1:0]      data_rid;
    logic [C.XLEN-1:0]               data_rdata;
    logic [C.DCACHE_USER_WIDTH-1:0]  data_ruser;
  } dcache_req_o_t;

  logic clk = 0, rst_n = 0;
  int checked = 0;
  int ptw_req_cnt = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_mmu_noncanon_hyp8");
    end
  endtask

  // MMU inputs
  logic                flush_i = 0;
  logic                en_tr = 1, en_ld_st_tr = 1;
  icache_arsp_t        fet_in = '0;
  icache_areq_t        mmu_areq, pmp_areq;
  exception_t          misal_ex = '0;
  logic                lsu_req = 0, lsu_is_store = 0, lsu_no_walk = 0;
  logic [C.VLEN-1:0]   lsu_vaddr = '0;
  logic                lsu_dtlb_hit;
  logic [C.PPNW-1:0]   lsu_dtlb_ppn;
  logic                mmu_lsu_valid, pmp_lsu_valid;
  logic [C.PLEN-1:0]   mmu_lsu_paddr, pmp_lsu_paddr;
  exception_t          mmu_lsu_ex, pmp_lsu_ex;
  logic                mmu_ex_ptw;
  riscv::priv_lvl_t    priv_lvl = riscv::PRIV_LVL_S;
  logic [C.PPNW-1:0]   satp_ppn = C.PPNW'(44'h80000);  // root PT @ 0x8000_0000
  riscv::pmpcfg_t [NPE-1:0] pmpcfg = '0;
  logic [NPE-1:0][C.PLEN-3:0] pmpaddr = '0;
  dcache_req_i_t       ptw_req;
  dcache_req_o_t       ptw_rsp;

  // Simple 1-cycle D$ responder for PTW: returns a valid 1 GiB leaf RWXAD
  // identity-mapped PTE (PPN2=2 -> PA 0x8000_0000..0xBFFF_FFFF, flags=0xEF)
  // for any root PTE read at VPN2=2 (offset 0x10), and 0 otherwise.
  logic [C.DCACHE_INDEX_WIDTH-1:0] req_idx_q;
  logic req_pend_q;
  logic [C.XLEN-1:0] pte_word;
  // Sv39 1G leaf PTE: PPN = 0x80000 (bit 29..10 -> PPN[2]=2), D=1 A=1 G=0 U=0 X=1 W=1 R=1 V=1 -> 0xEF
  localparam logic [63:0] LEAF_1G_PTE = (64'h0000_0000_0008_0000 << 10) | 64'h0000_0000_0000_00EF;

  assign ptw_rsp.data_gnt    = ptw_req.data_req;
  assign ptw_rsp.data_rvalid = req_pend_q;
  assign ptw_rsp.data_rid    = '0;
  assign ptw_rsp.data_ruser  = '0;
  assign ptw_rsp.data_rdata  = pte_word;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      req_pend_q <= 1'b0;
      req_idx_q  <= '0;
      pte_word   <= '0;
    end else begin
      if (ptw_req.data_req) ptw_req_cnt <= ptw_req_cnt + 1;
      req_pend_q <= ptw_req.data_req;
      req_idx_q  <= ptw_req.address_index;
      // VPN2=2 -> byte offset 2*8 = 16 = 0x10 inside root page
      pte_word   <= (ptw_req.address_index[11:0] == 12'h010) ? LEAF_1G_PTE : 64'h0;
    end
  end

  g6lc_mmu #(
      .G6LCCfg       (C),
      .HypCfg        (H),
      .icache_areq_t (icache_areq_t),
      .icache_arsp_t (icache_arsp_t),
      .icache_dreq_t (logic),
      .icache_drsp_t (logic),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t   (exception_t),
      .HYP_EXT       (0)
  ) i_mmu (
      .clk_i                   (clk),
      .rst_ni                  (rst_n),
      .flush_i                 (flush_i),
      .enable_translation_i    (en_tr),
      .enable_g_translation_i  (1'b0),
      .en_ld_st_translation_i  (en_ld_st_tr),
      .en_ld_st_g_translation_i(1'b0),
      .icache_areq_i           (fet_in),
      .icache_areq_o           (mmu_areq),
      .misaligned_ex_i         (misal_ex),
      .lsu_req_i               (lsu_req),
      .lsu_vaddr_i             (lsu_vaddr),
      .lsu_tinst_i             (32'h0),
      .lsu_is_store_i          (lsu_is_store),
      .lsu_no_walk_i           (lsu_no_walk),
      .csr_hs_ld_st_inst_o     (),
      .lsu_dtlb_hit_o          (lsu_dtlb_hit),
      .lsu_dtlb_ppn_o          (lsu_dtlb_ppn),
      .lsu_valid_o             (mmu_lsu_valid),
      .lsu_paddr_o             (mmu_lsu_paddr),
      .lsu_exception_o         (mmu_lsu_ex),
      .lsu_exception_ptw_o     (mmu_ex_ptw),
      .priv_lvl_i              (priv_lvl),
      .v_i                     (1'b0),
      .ld_st_priv_lvl_i        (priv_lvl),
      .ld_st_v_i               (1'b0),
      .sum_i                   (1'b0),
      .vs_sum_i                (1'b0),
      .mxr_i                   (1'b0),
      .vmxr_i                  (1'b0),
      .mbe_i                   (1'b0),
      .hlvx_inst_i             (1'b0),
      .hs_ld_st_inst_i         (1'b0),
      .satp_ppn_i              (satp_ppn),
      .vsatp_ppn_i             ('0),
      .hgatp_ppn_i             ('0),
      .asid_i                  ('0),
      .vs_asid_i               ('0),
      .asid_to_be_flushed_i    ('0),
      .vmid_i                  ('0),
      .vmid_to_be_flushed_i    ('0),
      .fetch_hart_i            ('0),
      .lsu_hart_i              ('0),
      .fet_asid_i              ('0),
      .fet_vs_asid_i           ('0),
      .fet_vmid_i              ('0),
      .fet_satp_ppn_i          (satp_ppn),
      .fet_vsatp_ppn_i         ('0),
      .fet_hgatp_ppn_i         ('0),
      .fet_mxr_i               (1'b0),
      .fet_vmxr_i              (1'b0),
      .fet_mbe_i               (1'b0),
      .fet_pmpcfg_i            (pmpcfg),
      .fet_pmpaddr_i           (pmpaddr),
      .vaddr_to_be_flushed_i   ('0),
      .gpaddr_to_be_flushed_i  ('0),
      .flush_tlb_i             (1'b0),
      .flush_tlb_vvma_i        (1'b0),
      .flush_tlb_gvma_i        (1'b0),
      .shared_tlb_flush_busy_o (),
      .itlb_miss_o             (),
      .dtlb_miss_o             (),
      .req_port_i              (ptw_rsp),
      .req_port_o              (ptw_req),
      .pmpcfg_i                (pmpcfg),
      .pmpaddr_i               (pmpaddr)
  );

  pmp_data_if #(
      .G6LCCfg            (C),
      .icache_areq_t      (icache_areq_t),
      .exception_t        (exception_t),
      .DATA_VERDICT_STAGES(0)
  ) i_pmp (
      .clk_i               (clk),
      .rst_ni              (rst_n),
      .icache_areq_i       (mmu_areq),
      .icache_areq_o       (pmp_areq),
      .icache_fetch_vaddr_i(fet_in.fetch_vaddr),
      .lsu_valid_i         (mmu_lsu_valid),
      .lsu_paddr_i         (mmu_lsu_paddr),
      .lsu_vaddr_i         (lsu_vaddr),
      .lsu_exception_i     (mmu_lsu_ex),
      .lsu_is_store_i      (lsu_is_store),
      .lsu_valid_o         (pmp_lsu_valid),
      .lsu_paddr_o         (pmp_lsu_paddr),
      .lsu_exception_o     (pmp_lsu_ex),
      .priv_lvl_i          (priv_lvl),
      .v_i                 (1'b0),
      .ld_st_priv_lvl_i    (priv_lvl),
      .ld_st_v_i           (1'b0),
      .pmpcfg_i            (pmpcfg),
      .pmpaddr_i           (pmpaddr),
      .fet_pmpcfg_i        (pmpcfg),
      .fet_pmpaddr_i       (pmpaddr)
  );

  initial begin
    // PMP entry 0: RWX over 0x8000_0000..0xFFFF_FFFF (2 GiB NAPOT).
    // PA 0x0000_0000..0x7FFF_FFFF is DENIED in S-mode — catches any PMP
    // overwrite of a higher-priority page fault whose stale paddr is 0.
    pmpcfg[0]  = '{locked: 1'b0, reserved: 2'b0,
                   addr_mode: riscv::NAPOT,
                   access_type: '{x: 1'b1, w: 1'b1, r: 1'b1}};
    pmpaddr[0] = 54'h2FFF_FFFF;

    repeat (3) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    // ---- S1: non-canonical fetch (exact r127m tracedb VA) ----
    // Low 39 bits map to VPN2=2 (0x8000_0000+ if bits[38:30]==2) OR unmapped;
    // try 0x6a09_e667_bb67_ae80 AND 0x1234_5600_8000_2000 (whose low 39 bits
    // ARE mapped by LEAF_1G_PTE!). Neither may trigger a PTW walk.
    ptw_req_cnt = 0;
    fet_in = '{fetch_req: 1'b1, fetch_vaddr: 64'h6a09_e667_bb67_ae80};
    #1;
    check(mmu_areq.fetch_valid === 1'b1, "NC_FET1_IMMED_VALID");
    check(mmu_areq.fetch_exception.valid === 1'b1, "NC_FET1_EX_VALID");
    check(mmu_areq.fetch_exception.cause === riscv::INSTR_PAGE_FAULT, "NC_FET1_CAUSE");
    check(mmu_areq.fetch_exception.tval  === 64'h6a09_e667_bb67_ae80, "NC_FET1_TVAL");
    tick();  // pmp_data_if registers fetch areq by 1 cycle
    #1;
    check(pmp_areq.fetch_valid === 1'b1, "NC_FET1_PMP_VALID");
    check(pmp_areq.fetch_exception.valid === 1'b1, "NC_FET1_PMP_EX_VALID");
    check(pmp_areq.fetch_exception.cause === riscv::INSTR_PAGE_FAULT, "NC_FET1_PMP_CAUSE");
    repeat (10) tick();
    check(ptw_req_cnt == 0, "NC_FET1_NO_PTW");
    fet_in = '0;
    repeat (2) tick();

    // S1b: non-canonical fetch whose low 39 bits (0x8000_2000) ARE mapped!
    fet_in = '{fetch_req: 1'b1, fetch_vaddr: 64'h1234_5600_8000_2000};
    #1;
    check(mmu_areq.fetch_valid === 1'b1, "NC_FET2_IMMED_VALID");
    check(mmu_areq.fetch_exception.cause === riscv::INSTR_PAGE_FAULT, "NC_FET2_CAUSE");
    repeat (10) tick();
    check(ptw_req_cnt == 0, "NC_FET2_NO_PTW");
    fet_in = '0;
    repeat (2) tick();

    // ---- S2: non-canonical load (0x6a09_e667_bb67_ae80) ----
    lsu_req      = 1'b1;
    lsu_is_store = 1'b0;
    lsu_vaddr    = 64'h6a09_e667_bb67_ae80;
    #1;
    check(lsu_dtlb_hit === 1'b0, "NC_LD_NO_HIT");
    tick();  // registered lsu_req_q / lsu_vaddr_q
    #1;
    check(mmu_lsu_valid === 1'b1, "NC_LD_MMU_VALID");
    check(mmu_lsu_ex.valid === 1'b1, "NC_LD_MMU_EX");
    check(mmu_lsu_ex.cause === riscv::LOAD_PAGE_FAULT, "NC_LD_MMU_CAUSE");
    check(pmp_lsu_valid === 1'b1, "NC_LD_PMP_VALID");
    check(pmp_lsu_ex.valid === 1'b1, "NC_LD_PMP_EX");
    check(pmp_lsu_ex.cause === riscv::LOAD_PAGE_FAULT, "NC_LD_PMP_NOT_OVERWRITTEN");
    check(pmp_lsu_ex.tval  === 64'h6a09_e667_bb67_ae80, "NC_LD_TVAL");
    repeat (10) tick();
    check(ptw_req_cnt == 0, "NC_LD_NO_PTW");
    lsu_req = 1'b0;
    repeat (2) tick();

    // ---- S3: non-canonical store (bit 38=1, upper bits 0) ----
    lsu_req      = 1'b1;
    lsu_is_store = 1'b1;
    lsu_vaddr    = 64'h0000_0040_0000_1000;
    #1;
    check(lsu_dtlb_hit === 1'b0, "NC_ST_NO_HIT");
    tick();
    #1;
    check(mmu_lsu_valid === 1'b1, "NC_ST_MMU_VALID");
    check(mmu_lsu_ex.cause === riscv::STORE_PAGE_FAULT, "NC_ST_MMU_CAUSE");
    check(pmp_lsu_ex.cause === riscv::STORE_PAGE_FAULT, "NC_ST_PMP_NOT_OVERWRITTEN");
    check(pmp_lsu_ex.tval  === 64'h0000_0040_0000_1000, "NC_ST_TVAL");
    repeat (10) tick();
    check(ptw_req_cnt == 0, "NC_ST_NO_PTW");
    lsu_req = 1'b0;
    repeat (2) tick();

    // ---- S4: canonical mapped Sv39 fetch & load (regression) ----
    // VA 0x0000_0000_8000_2000 (VPN2=2 -> LEAF_1G_PTE -> PA 0x8000_2000)
    fet_in = '{fetch_req: 1'b1, fetch_vaddr: 64'h0000_0000_8000_2000};
    begin
      int cyc = 0;
      while (!pmp_areq.fetch_valid && cyc < 40) begin
        if (!mmu_areq.fetch_valid)
          check(mmu_areq.fetch_exception.valid === 1'b0, "CAN_FET_WALK_NO_SPURIOUS_EX");
        tick();
        cyc++;
      end
      check(pmp_areq.fetch_valid === 1'b1, "CAN_FET_VALID");
      check(pmp_areq.fetch_exception.valid === 1'b0, "CAN_FET_NO_EX");
      check(pmp_areq.fetch_paddr === C.PLEN'(64'h0000_0000_8000_2000), "CAN_FET_PA");
      check(ptw_req_cnt > 0, "CAN_FET_WALKED");
    end
    fet_in = '0;
    repeat (2) tick();

    lsu_req      = 1'b1;
    lsu_is_store = 1'b0;
    lsu_vaddr    = 64'h0000_0000_8000_3456;
    begin
      int cyc = 0;
      while (!pmp_lsu_valid && cyc < 40) begin
        tick();
        cyc++;
      end
      check(pmp_lsu_valid === 1'b1, "CAN_LD_VALID");
      check(pmp_lsu_ex.valid === 1'b0, "CAN_LD_NO_EX");
      check(pmp_lsu_paddr === C.PLEN'(64'h0000_0000_8000_3456), "CAN_LD_PA");
    end
    lsu_req = 1'b0;
    repeat (4) tick();

    // ---- S5: stale 1-cycle fetch redirect (mret phys-alias pattern) ----
    // Present an unmapped VA (0x0000_0000_4000_04f0, VPN2=1) for 1 cycle and
    // immediately redirect to an ITLB-cached VA (0x0000_0000_8000_2000) before
    // the STLB_DLY=2 verdict lands. Without stale-miss suppression, the dead
    // 0x4000_04f0 miss pops out 2 cycles later and launches a wasted PTW walk.
    begin
      int ptw_before = ptw_req_cnt;
      fet_in = '{fetch_req: 1'b1, fetch_vaddr: 64'h0000_0000_4000_04f0};
      tick();
      fet_in = '{fetch_req: 1'b1, fetch_vaddr: 64'h0000_0000_8000_2000};
      repeat (12) tick();
      check(ptw_req_cnt == ptw_before, "STALE_FET_NO_PTW");
      check(pmp_areq.fetch_valid === 1'b1, "STALE_FET_REDIR_HIT");
      check(pmp_areq.fetch_exception.valid === 1'b0, "STALE_FET_REDIR_NO_EX");
      fet_in = '0;
      repeat (2) tick();
    end

    // ---- S6: stale 1-cycle cancelled load (mret/wrong-path phys-alias) ----
    // Present an unmapped load VA (0x0000_0000_4004_5df0) for 1 cycle, then
    // cancel/drop lsu_req before STLB_DLY=2. Must NOT launch a PTW walk.
    begin
      int ptw_before = ptw_req_cnt;
      lsu_req      = 1'b1;
      lsu_is_store = 1'b0;
      lsu_vaddr    = 64'h0000_0000_4004_5df0;
      tick();
      lsu_req      = 1'b0;
      repeat (12) tick();
      check(ptw_req_cnt == ptw_before, "STALE_LD_NO_PTW");
    end

    // ---- S7: speculative DTLB probe (lsu_no_walk_i=1) ----
    // 7a: DTLB-cached VA (0x0000_0000_8000_3456) hits in 2 cycles even with
    //     lsu_no_walk_i=1 (unblocks OoO speculative loads under TlbStages=3).
    // 7b: Unmapped VA (0x0000_0000_4008_0000) held for 12 cycles with
    //     lsu_no_walk_i=1 MUST NOT launch any PTW walk (preserves rfix131a-03);
    //     when lsu_no_walk_i drops (commit time), the walk fires normally.
    begin
      int ptw_before = ptw_req_cnt;
      lsu_no_walk  = 1'b1;
      lsu_req      = 1'b1;
      lsu_is_store = 1'b0;
      lsu_vaddr    = 64'h0000_0000_8000_3456;
      repeat (2) tick();
      #1;
      check(lsu_dtlb_hit === 1'b1, "SPEC_PROBE_HIT");
      check(ptw_req_cnt == ptw_before, "SPEC_PROBE_HIT_NO_PTW");

      lsu_vaddr = 64'h0000_0000_4008_0000;
      repeat (12) tick();
      check(lsu_dtlb_hit === 1'b0, "SPEC_PROBE_MISS");
      check(ptw_req_cnt == ptw_before, "SPEC_PROBE_MISS_NO_PTW");

      lsu_no_walk = 1'b0;  // becomes commit head -> walk proceeds
      repeat (10) tick();
      check(ptw_req_cnt > ptw_before, "SPEC_PROMOTE_WALKS");
      lsu_req = 1'b0;
      repeat (2) tick();
    end

    // ---- S8: Staged TLB privilege-switch currency (Q2 U<->S without ASID change) ----
    // VA 0x8000_2000 is cached in ITLB (supervisor page, pte.u=0). Launch lookup
    // under S-mode, switch priv_lvl S -> U on cycle +1 while keeping VA & ASID:
    // on cycle +2 the stale S-mode lookup must NOT fire a spurious U-mode fault.
    priv_lvl = riscv::PRIV_LVL_S;
    fet_in   = '{fetch_req: 1'b1, fetch_vaddr: 64'h0000_0000_8000_2000};
    tick();  // cycle +1: lookup in stage 1 under priv=S
    priv_lvl = riscv::PRIV_LVL_U;
    tick();  // cycle +2: stage 2 answer arrives, but priv changed S->U!
    #1;
    check(mmu_areq.fetch_valid === 1'b0, "STLB_PRIV_SWITCH_NO_SPURIOUS_EX");
    fet_in   = '0;
    priv_lvl = riscv::PRIV_LVL_S;
    repeat (2) tick();

    $display("PASS tb_g6lc_mmu_noncanon_hyp8 checked=%0d ptw_reqs=%0d", checked, ptw_req_cnt);
    $finish;
  end
endmodule
