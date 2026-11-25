// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 MMU miss-router & PTW leaf verifying 4 real RTL bug fixes:
//   B1. g6lc_tlb_miss_router: ITLB miss must NOT be starved by a DTLB HIT
//       (dtlb_access_i=1 && dtlb_hit_i=1).
//   B3. g6lc_ptw (Svpbmt): non-leaf PTE with pbmt!=0 must raise ptw_error_o.
//   B4. g6lc_ptw (Svnapot): illegal NAPOT leaf (n=1, ppn[3:0]!=4'b1000) must
//       raise ptw_error_o AND keep shared_tlb_update_o.valid===0 (no TLB poison).
//   B5. g6lc_ptw: flush_i on PTE_DECODE verdict cycle must suppress
//       shared_tlb_update_o.valid===0.
//
// Review mutations (each must fail):
//   -DG6LC_MUT_MMU_ITLB_BLOCK_DHIT -> fails B1_ITLB_NOT_BLOCKED_BY_DHIT
//   -DG6LC_MUT_PTW_PBMT_NONLEAF    -> fails B3_PBMT_NONLEAF_FAULTS
//   -DG6LC_MUT_PTW_NAPOT_POISON    -> fails B4_NAPOT_NO_TLB_POISON
//   -DG6LC_MUT_PTW_FLUSH_FILL      -> fails B5_FLUSH_SUPPRESSES_FILL
//
// PASS token: PASS tb_g6lc_ptw_router_hyp8
`include "g6lc_core_types.svh"

module tb_g6lc_ptw_router_hyp8;
  import g6lc_core_pkg::*;

  function automatic config_pkg::g6lc_cfg_t mk_cfg();
    config_pkg::g6lc_cfg_t c = g6lc_config_pkg::g6lc_cfg;
    c.SvpbmtEn  = 1'b1;
    c.SvnapotEn = 1'b1;
    return build_config_pkg::build_config(c);
  endfunction
  localparam config_pkg::g6lc_cfg_t C = mk_cfg();
  localparam g6lc_hyp_pkg::g6lc_hyp_cfg_t H = g6lc_hyp_pkg::Hyp8;
  localparam int unsigned HID_W = $clog2(C.NrHarts > 1 ? C.NrHarts : 2);

  typedef struct packed {
    logic n;
    logic [1:0] pbmt;
    logic [6:0] reserved;
    logic [C.PPNW-1:0] ppn;
    logic [1:0] rsw;
    logic d, a, g, u, x, w, r, v;
  } pte_g6lc_t;
  typedef struct packed {
    logic valid;
    logic [C.PtLevels-2:0][0:0] is_page;
    logic [C.VpnLen-1:0] vpn;
    logic [C.ASID_WIDTH-1:0] asid;
    logic [C.VMID_WIDTH-1:0] vmid;
    logic [HID_W-1:0] hart;
    logic [0:0] v_st_enbl;
    pte_g6lc_t content;
    pte_g6lc_t g_content;
    logic is_napot_64k;
  } tlb_upd_t;
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
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_ptw_router_hyp8");
    end
  endtask

  // ---- DUT 1: g6lc_tlb_miss_router ----
  logic r_iacc = 0, r_ihit = 0, r_dacc = 0, r_dhit = 0;
  logic r_stlb_acc, r_ireq;
  g6lc_tlb_miss_router #(
      .G6LCCfg          (C),
      .tlb_update_g6lc_t(tlb_upd_t),
      .HYP_EXT          (0)
  ) i_router (
      .clk_i              (clk),
      .rst_ni             (rst_n),
      .flush_i            (1'b0),
      .flush_vvma_i       (1'b0),
      .flush_gvma_i       (1'b0),
      .s_st_enbl_i        (1'b1),
      .g_st_enbl_i        (1'b0),
      .v_i                (1'b0),
      .s_ld_st_enbl_i     (1'b1),
      .g_ld_st_enbl_i     (1'b0),
      .ld_st_v_i          (1'b0),
      .itlb_access_i      (r_iacc),
      .itlb_hit_i         (r_ihit),
      .itlb_vaddr_i       (64'h0000_0000_8000_2000),
      .dtlb_access_i      (r_dacc),
      .dtlb_hit_i         (r_dhit),
      .dtlb_vaddr_i       (64'h0000_0000_8000_4000),
      .shared_tlb_miss_i  (1'b0),
      .shared_tlb_update_i('0),
      .itlb_update_o      (),
      .dtlb_update_o      (),
      .itlb_miss_o        (),
      .dtlb_miss_o        (),
      .flush_busy_o       (),
      .shared_tlb_access_o(r_stlb_acc),
      .shared_tlb_hit_o   (),
      .shared_tlb_vaddr_o (),
      .itlb_req_o         (r_ireq)
  );

  // ---- DUT 2: g6lc_ptw (PtwDecodeStage==1, SvpbmtEn=1, SvnapotEn=1) ----
  logic          p_flush = 0, p_stlb_acc = 0, p_ireq = 0;
  logic          p_active, p_err, p_acc_ex;
  tlb_upd_t      p_upd;
  dcache_req_i_t p_req;
  dcache_req_o_t p_rsp = '0;
  riscv::pmpcfg_t [C.NrPMPEntries-1:0] pmpcfg = '{default: '0};
  logic [C.NrPMPEntries-1:0][C.PLEN-3:0] pmpaddr = '{default: '0};

  g6lc_ptw #(
      .G6LCCfg          (C),
      .HypCfg           (H),
      .pte_g6lc_t       (pte_g6lc_t),
      .tlb_update_g6lc_t(tlb_upd_t),
      .dcache_req_i_t   (dcache_req_i_t),
      .dcache_req_o_t   (dcache_req_o_t),
      .HYP_EXT          (0)
  ) i_ptw (
      .clk_i                   (clk),
      .rst_ni                  (rst_n),
      .flush_i                 (p_flush),
      .ptw_active_o            (p_active),
      .walking_instr_o         (),
      .ptw_error_o             (p_err),
      .ptw_error_at_g_st_o     (),
      .ptw_err_at_g_int_st_o   (),
      .ptw_access_exception_o  (p_acc_ex),
      .enable_translation_i    (1'b1),
      .enable_g_translation_i  (1'b0),
      .en_ld_st_translation_i  (1'b1),
      .en_ld_st_g_translation_i(1'b0),
      .v_i                     (1'b0),
      .ld_st_v_i               (1'b0),
      .hlvx_inst_i             (1'b0),
      .lsu_is_store_i          (1'b0),
      .shared_tlb_access_i     (p_stlb_acc),
      .shared_tlb_hit_i        (1'b0),
      .shared_tlb_vaddr_i      (64'h0000_0000_8000_2000),
      .itlb_req_i              (p_ireq),
      .shared_tlb_miss_o       (),
      .shared_tlb_update_o     (p_upd),
      .update_vaddr_o          (),
      .asid_i                  ('0),
      .vmid_i                  ('0),
      .req_hart_i              ('0),
      .satp_ppn_i              (C.PPNW'(44'h80000)),
      .vsatp_ppn_i             ('0),
      .hgatp_ppn_i             ('0),
      .mxr_i                   (1'b0),
      .vmxr_i                  (1'b0),
      .req_port_i              (p_rsp),
      .req_port_o              (p_req),
      .pmpcfg_i                (pmpcfg),
      .pmpaddr_i               (pmpaddr),
      .bad_paddr_o             (),
      .bad_gpaddr_o            (),
      .mbe_i                   (1'b0)
  );

  // Helper: launch a 1-step PTW walk and feed PTE word `w` on data_rvalid
  task automatic feed_pte(input logic [63:0] pte_word, input bit flush_on_decode,
                          output bit saw_err, output bit saw_upd);
    saw_err = 0; saw_upd = 0;
    p_stlb_acc = 1'b1; p_ireq = 1'b1;
    tick();  // IDLE -> WAIT_GRANT
    p_stlb_acc = 1'b0;
    p_rsp = '{data_gnt: 1'b1, default: '0};
    tick();  // WAIT_GRANT -> PTE_LOOKUP
    p_rsp = '{data_rvalid: 1'b1, data_rdata: pte_word, default: '0};
    tick();  // data_rvalid_q <= 1, pte_q <= pte_word
    p_rsp = '0;
    tick();  // PTE_LOOKUP (data_rvalid_q=1) -> PTE_DECODE
    // Now state_q == PTE_DECODE!
    if (flush_on_decode) p_flush = 1'b1;
    #1;
    if (p_upd.valid) saw_upd = 1;
    tick();  // PTE_DECODE -> PROPAGATE_ERROR or LATENCY
    p_flush = 1'b0;
    #1;
    if (p_err) saw_err = 1;
    if (p_upd.valid) saw_upd = 1;
    repeat (4) tick();
  endtask

  initial begin
    pmpcfg[0]  = '{locked: 1'b0, reserved: 2'b0, addr_mode: riscv::NAPOT,
                   access_type: '{x: 1'b1, w: 1'b1, r: 1'b1}};
    pmpaddr[0] = '1;
    repeat (3) tick();
    rst_n = 1'b1;
    repeat (2) tick();

    // ---- B1: ITLB miss must NOT be starved by a DTLB HIT ----
    r_iacc = 1'b1; r_ihit = 1'b0;  // ITLB MISS
    r_dacc = 1'b1; r_dhit = 1'b1;  // DTLB HIT (does not need PTW!)
    tick();
    #1;
    check(r_stlb_acc === 1'b1 && r_ireq === 1'b1, "B1_ITLB_NOT_BLOCKED_BY_DHIT");
    // When DTLB MISSES too, DTLB still wins priority
    r_dhit = 1'b0;
    tick();
    #1;
    check(r_stlb_acc === 1'b1 && r_ireq === 1'b0, "B1_DTLB_MISS_STILL_WINS");
    r_iacc = 1'b0; r_dacc = 1'b0;
    tick();

    // ---- B3: Svpbmt non-leaf PTE (r=0,w=0,x=0,v=1) with pbmt=01 MUST fault ----
    // Bit 61 = 1 (pbmt=01), ppn=0x80001, v=1 -> 64'h2000_0000_2000_0401
    begin
      bit e, u;
      feed_pte(64'h2000_0000_2000_0401, 1'b0, e, u);
      check(e === 1'b1 && u === 1'b0, "B3_PBMT_NONLEAF_FAULTS");
    end

    // ---- B4: Svnapot illegal leaf (n=1, lvl=0 1G page, r=x=a=v=1) MUST fault & NOT update TLB ----
    // Bit 63 = 1 (n=1), ppn=0x80000 (1G aligned), a=1,x=1,r=1,v=1 (0x4b) -> 64'h8000_0000_2000_004b
    begin
      bit e, u;
      feed_pte(64'h8000_0000_2000_004b, 1'b0, e, u);
      check(e === 1'b1, "B4_NAPOT_ILLEGAL_FAULTS");
      check(u === 1'b0, "B4_NAPOT_NO_TLB_POISON");
    end

    // ---- B5: Legal leaf PTE with flush_i on PTE_DECODE MUST NOT install TLB update ----
    // Valid 1G leaf: ppn=0x80000, a=1,x=1,r=1,v=1 -> 64'h0000_0000_2000_004b
    begin
      bit e, u;
      feed_pte(64'h0000_0000_2000_004b, 1'b1, e, u);
      check(u === 1'b0, "B5_FLUSH_SUPPRESSES_FILL");
      // Without flush_i, the exact same legal leaf MUST install cleanly!
      feed_pte(64'h0000_0000_2000_004b, 1'b0, e, u);
      check(e === 1'b0 && u === 1'b1, "B5_LEGAL_LEAF_FILLS");
    end

    $display("PASS tb_g6lc_ptw_router_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
