// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// Isolated hyp8 g6lc_shared_tlb leaf (N4): proves simultaneous PTW fill to
// set A (way 0) + ITLB miss lookup of set B under UseSharedTlb=1 NEVER
// aliases tag_sram/pte_sram read address to set A while shared_tag_valid
// samples set B (which otherwise returns set A's PTE as a false hit for set B!).
//
// Scenarios:
//   S1. Install 2M superpage P_A at set 0 (VPN=0x001_000, PPN=0x81000) into way 0
//       and dummy entry at set 1 way 0 so set 1 has valid way 0.
//   S2. On the SAME cycle: PTW writes set 0 way 1 (VPN=0x002_000) WHILE an
//       ITLB miss queries set 1 with VPN=0x001_001 (same upper VPN[26:9]=0x001
//       as set 0's 2M superpage in way 0!).
//       - Fixed: lookup holds quiet during fill -> shared_tlb_hit_o===0, no
//         corrupted itlb_update_o!
//       - Mutant (-DG6LC_MUT_STLB_RW_COLLIDE): tag_addr redirects way 0 read
//         to set 0 while shared_tag_valid[0] comes from set 1 -> FALSE HIT
//         returning set 0's 2M superpage (PPN=0x81000) for set 1!
//   S3. Next cycle (fill idle): ordinary shared-TLB hit on set 0 succeeds cleanly.
//
// PASS token: PASS tb_g6lc_stlb_rw_hyp8
module tb_g6lc_stlb_rw_hyp8;
  import g6lc_core_pkg::*;

  function automatic config_pkg::g6lc_cfg_t mk_cfg();
    config_pkg::g6lc_cfg_t c = build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
    c.UseSharedTlb   = 1'b1;
    c.SharedTlbDepth = 64;
    return c;
  endfunction
  localparam config_pkg::g6lc_cfg_t C = mk_cfg();
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

  logic clk = 0, rst_n = 0;
  int checked = 0;
  always #5 clk = ~clk;
  task tick(); @(posedge clk); #1; endtask
  task check(input logic cond, input string name);
    checked++;
    if (!cond) begin
      $display("FAIL %s", name);
      $fatal(1, "tb_g6lc_stlb_rw_hyp8");
    end
  endtask

  logic                 iacc = 0, ihit = 0, dacc = 0, dhit = 0;
  logic [C.VLEN-1:0]    iva = '0, dva = '0;
  tlb_upd_t             stlb_upd = '0, iupd, dupd;
  logic                 stlb_acc, stlb_hit;

  g6lc_shared_tlb #(
      .G6LCCfg          (C),
      .SHARED_TLB_WAYS  (2),
      .HYP_EXT          (0),
      .pte_g6lc_t       (pte_g6lc_t),
      .tlb_update_g6lc_t(tlb_upd_t)
  ) dut (
      .clk_i                  (clk),
      .rst_ni                 (rst_n),
      .flush_i                (1'b0),
      .flush_vvma_i           (1'b0),
      .flush_gvma_i           (1'b0),
      .s_st_enbl_i            (1'b1),
      .g_st_enbl_i            (1'b0),
      .v_i                    (1'b0),
      .s_ld_st_enbl_i         (1'b1),
      .g_ld_st_enbl_i         (1'b0),
      .ld_st_v_i              (1'b0),
      .itlb_access_i          (iacc),
      .itlb_hit_i             (ihit),
      .itlb_vaddr_i           (iva),
      .dtlb_access_i          (dacc),
      .dtlb_hit_i             (dhit),
      .dtlb_vaddr_i           (dva),
      .itlb_asid_i            ('0),
      .dtlb_asid_i            ('0),
      .itlb_vmid_i            ('0),
      .lu_vmid_i              ('0),
      .itlb_hart_i            ('0),
      .dtlb_hart_i            ('0),
      .asid_to_be_flushed_i   ('0),
      .vaddr_to_be_flushed_i  ('0),
      .vmid_to_be_flushed_i   ('0),
      .gpaddr_to_be_flushed_i ('0),
      .itlb_update_o          (iupd),
      .dtlb_update_o          (dupd),
      .itlb_miss_o            (),
      .dtlb_miss_o            (),
      .flush_busy_o           (),
      .shared_tlb_access_o    (stlb_acc),
      .shared_tlb_hit_o       (stlb_hit),
      .shared_tlb_vaddr_o     (),
      .itlb_req_o             (),
      .shared_tlb_miss_i      (1'b0),
      .shared_tlb_update_i    (stlb_upd)
  );

  function automatic tlb_upd_t mk_fill(input logic [26:0] vpn, input logic [43:0] ppn, input logic is_2m);
    tlb_upd_t u = '0;
    u.valid     = 1'b1;
    u.vpn       = vpn;
    u.is_page[1][0] = is_2m;  // 2M superpage (lvl 1)
    u.v_st_enbl = 1'b1;
    u.content.ppn = ppn;
    u.content.v = 1'b1; u.content.r = 1'b1; u.content.x = 1'b1; u.content.a = 1'b1;
    return u;
  endfunction

  initial begin
    repeat (3) tick();
    rst_n = 1'b1;
    tick();

    // S1: Fill set 0 way 0 with 2M superpage VPN=0x001_000 (PPN=0x81000)
    //     Fill set 1 way 0 with 4K page VPN=0x009_001 (PPN=0x89000) so set 1 way 0 is valid!
    stlb_upd = mk_fill(27'h001_000, 44'h81000, 1'b1);
    tick();
    stlb_upd = mk_fill(27'h009_001, 44'h89000, 1'b0);
    tick();
    stlb_upd = '0;
    tick();

    // S2: SAME CYCLE: fill set 0 way 1 (VPN=0x002_000) WHILE ITLB miss queries
    //     set 1 with VPN=0x001_001 (same VPN[26:9]=0x0008 as set 0's 2M superpage!).
    //     Under G6LC_MUT_STLB_RW_COLLIDE, tag_addr redirects way 0 read to set 0
    //     while shared_tag_valid[0] comes from set 1 (valid=1!) -> FALSE HIT!
    stlb_upd = mk_fill(27'h002_000, 44'h82000, 1'b0);
    iacc     = 1'b1;
    ihit     = 1'b0;
    iva      = {25'd0, 27'h001_001, 12'd0};
    tick();
    stlb_upd = '0;
    iacc     = 1'b0;
    #1;
    check(stlb_hit === 1'b0 && iupd.valid === 1'b0, "S2_NO_RW_ALIAS_FALSE_HIT");
    tick();

    // S3: Normal lookup of set 0 (VPN=0x001_000) when no write is active MUST hit!
    iacc = 1'b1; ihit = 1'b0;
    iva  = {25'd0, 27'h001_000, 12'd0};
    tick();
    #1;
    if (!(stlb_hit === 1'b1 && iupd.valid === 1'b1 && iupd.content.ppn === 44'h81000))
      $display("DBG S3 hit=%b iupd_v=%b ppn=%h vld=%b ma=%b ms=%b lm0=%b lm1=%b vpnq=%h tag0=%h",
               stlb_hit, iupd.valid, iupd.content.ppn, dut.shared_tag_valid,
               dut.match_asid, dut.match_stage, dut.level_match[0], dut.level_match[1],
               dut.vpn_q, dut.shared_tag_rd[0].vpn);
    check(stlb_hit === 1'b1 && iupd.valid === 1'b1 && iupd.content.ppn === 44'h81000, "S3_NORMAL_HIT_OK");
    iacc = 1'b0;

    $display("PASS tb_g6lc_stlb_rw_hyp8 checked=%0d", checked);
    $finish;
  end
endmodule
