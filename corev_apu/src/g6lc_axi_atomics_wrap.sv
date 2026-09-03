// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Testharness DRAM exclusive path for S4/CLASS1: g6lc_axi_lrsc first so
// AxLOCK is seen before AMOS (HPDCACHE STEX/LDEX), AXI cut, then vendor
// AMO adapter. +1 cycle vs pulp wrap. Live cookie keeps
// axi_riscv_atomics_wrap. Same AXI_BUS ports as the pulp wrap.

`include "axi/assign.svh"

module g6lc_axi_atomics_wrap #(
    parameter int unsigned AXI_ADDR_WIDTH     = 64,
    parameter int unsigned AXI_DATA_WIDTH     = 64,
    parameter int unsigned AXI_ID_WIDTH       = 4,
    parameter int unsigned AXI_USER_WIDTH     = 1,
    parameter int unsigned AXI_MAX_WRITE_TXNS = 8,
    parameter int unsigned RISCV_WORD_WIDTH   = 64,
    // Concurrent LR/SC reservations. Must be >= the number of software harts
    // that can hold one at the same time, or two harts reserving *different*
    // addresses evict each other and neither SC can make progress. The SoC
    // passes its own hart count; see g6lc_axi_lrsc for the argument.
    parameter int unsigned NRes               = 8
) (
    input  logic   clk_i,
    input  logic   rst_ni,
    AXI_BUS.Master mst,
    AXI_BUS.Slave  slv
);

  AXI_BUS #(
      .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
      .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
      .AXI_USER_WIDTH ( AXI_USER_WIDTH )
  ) lrsc_m();
  AXI_BUS #(
      .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH ),
      .AXI_DATA_WIDTH ( AXI_DATA_WIDTH ),
      .AXI_ID_WIDTH   ( AXI_ID_WIDTH   ),
      .AXI_USER_WIDTH ( AXI_USER_WIDTH )
  ) amos_s();

  g6lc_axi_lrsc #(
      .AXI_ADDR_WIDTH ( AXI_ADDR_WIDTH     ),
      .AXI_DATA_WIDTH ( AXI_DATA_WIDTH     ),
      .AXI_ID_WIDTH   ( AXI_ID_WIDTH       ),
      .AXI_USER_WIDTH ( AXI_USER_WIDTH     ),
      .MaxOut         ( AXI_MAX_WRITE_TXNS ),
      .NRes           ( NRes               )
  ) i_lrsc (
      .clk_i,
      .rst_ni,
      .slv ( slv ),
      .mst ( lrsc_m )
  );

  // Cut between lrsc and AMOS (AMOS is combinational).
  axi_cut_intf #(
      .BYPASS     ( 1'b0 ),
      .ADDR_WIDTH ( AXI_ADDR_WIDTH ),
      .DATA_WIDTH ( AXI_DATA_WIDTH ),
      .ID_WIDTH   ( AXI_ID_WIDTH   ),
      .USER_WIDTH ( AXI_USER_WIDTH )
  ) i_cut (
      .clk_i,
      .rst_ni,
      .in  ( lrsc_m ),
      .out ( amos_s )
  );

  axi_riscv_amos #(
      .AXI_ADDR_WIDTH     ( AXI_ADDR_WIDTH     ),
      .AXI_DATA_WIDTH     ( AXI_DATA_WIDTH     ),
      .AXI_ID_WIDTH       ( AXI_ID_WIDTH       ),
      .AXI_USER_WIDTH     ( AXI_USER_WIDTH     ),
      .AXI_MAX_WRITE_TXNS ( AXI_MAX_WRITE_TXNS ),
      .RISCV_WORD_WIDTH   ( RISCV_WORD_WIDTH   )
  ) i_amos (
      .clk_i           ( clk_i         ),
      .rst_ni          ( rst_ni        ),
      .slv_aw_addr_i   ( amos_s.aw_addr   ),
      .slv_aw_prot_i   ( amos_s.aw_prot   ),
      .slv_aw_region_i ( amos_s.aw_region ),
      .slv_aw_atop_i   ( amos_s.aw_atop   ),
      .slv_aw_len_i    ( amos_s.aw_len    ),
      .slv_aw_size_i   ( amos_s.aw_size   ),
      .slv_aw_burst_i  ( amos_s.aw_burst  ),
      .slv_aw_lock_i   ( amos_s.aw_lock   ),
      .slv_aw_cache_i  ( amos_s.aw_cache  ),
      .slv_aw_qos_i    ( amos_s.aw_qos    ),
      .slv_aw_id_i     ( amos_s.aw_id     ),
      .slv_aw_user_i   ( amos_s.aw_user   ),
      .slv_aw_ready_o  ( amos_s.aw_ready  ),
      .slv_aw_valid_i  ( amos_s.aw_valid  ),
      .slv_ar_addr_i   ( amos_s.ar_addr   ),
      .slv_ar_prot_i   ( amos_s.ar_prot   ),
      .slv_ar_region_i ( amos_s.ar_region ),
      .slv_ar_len_i    ( amos_s.ar_len    ),
      .slv_ar_size_i   ( amos_s.ar_size   ),
      .slv_ar_burst_i  ( amos_s.ar_burst  ),
      .slv_ar_lock_i   ( amos_s.ar_lock   ),
      .slv_ar_cache_i  ( amos_s.ar_cache  ),
      .slv_ar_qos_i    ( amos_s.ar_qos    ),
      .slv_ar_id_i     ( amos_s.ar_id     ),
      .slv_ar_user_i   ( amos_s.ar_user   ),
      .slv_ar_ready_o  ( amos_s.ar_ready  ),
      .slv_ar_valid_i  ( amos_s.ar_valid  ),
      .slv_w_data_i    ( amos_s.w_data    ),
      .slv_w_strb_i    ( amos_s.w_strb    ),
      .slv_w_user_i    ( amos_s.w_user    ),
      .slv_w_last_i    ( amos_s.w_last    ),
      .slv_w_ready_o   ( amos_s.w_ready   ),
      .slv_w_valid_i   ( amos_s.w_valid   ),
      .slv_r_data_o    ( amos_s.r_data    ),
      .slv_r_resp_o    ( amos_s.r_resp    ),
      .slv_r_last_o    ( amos_s.r_last    ),
      .slv_r_id_o      ( amos_s.r_id      ),
      .slv_r_user_o    ( amos_s.r_user    ),
      .slv_r_ready_i   ( amos_s.r_ready   ),
      .slv_r_valid_o   ( amos_s.r_valid   ),
      .slv_b_resp_o    ( amos_s.b_resp    ),
      .slv_b_id_o      ( amos_s.b_id      ),
      .slv_b_user_o    ( amos_s.b_user    ),
      .slv_b_ready_i   ( amos_s.b_ready   ),
      .slv_b_valid_o   ( amos_s.b_valid   ),
      .mst_aw_addr_o   ( mst.aw_addr   ),
      .mst_aw_prot_o   ( mst.aw_prot   ),
      .mst_aw_region_o ( mst.aw_region ),
      .mst_aw_atop_o   ( mst.aw_atop   ),
      .mst_aw_len_o    ( mst.aw_len    ),
      .mst_aw_size_o   ( mst.aw_size   ),
      .mst_aw_burst_o  ( mst.aw_burst  ),
      .mst_aw_lock_o   ( mst.aw_lock   ),
      .mst_aw_cache_o  ( mst.aw_cache  ),
      .mst_aw_qos_o    ( mst.aw_qos    ),
      .mst_aw_id_o     ( mst.aw_id     ),
      .mst_aw_user_o   ( mst.aw_user   ),
      .mst_aw_ready_i  ( mst.aw_ready  ),
      .mst_aw_valid_o  ( mst.aw_valid  ),
      .mst_ar_addr_o   ( mst.ar_addr   ),
      .mst_ar_prot_o   ( mst.ar_prot   ),
      .mst_ar_region_o ( mst.ar_region ),
      .mst_ar_len_o    ( mst.ar_len    ),
      .mst_ar_size_o   ( mst.ar_size   ),
      .mst_ar_burst_o  ( mst.ar_burst  ),
      .mst_ar_lock_o   ( mst.ar_lock   ),
      .mst_ar_cache_o  ( mst.ar_cache  ),
      .mst_ar_qos_o    ( mst.ar_qos    ),
      .mst_ar_id_o     ( mst.ar_id     ),
      .mst_ar_user_o   ( mst.ar_user   ),
      .mst_ar_ready_i  ( mst.ar_ready  ),
      .mst_ar_valid_o  ( mst.ar_valid  ),
      .mst_w_data_o    ( mst.w_data    ),
      .mst_w_strb_o    ( mst.w_strb    ),
      .mst_w_user_o    ( mst.w_user    ),
      .mst_w_last_o    ( mst.w_last    ),
      .mst_w_ready_i   ( mst.w_ready   ),
      .mst_w_valid_o   ( mst.w_valid   ),
      .mst_r_data_i    ( mst.r_data    ),
      .mst_r_resp_i    ( mst.r_resp    ),
      .mst_r_last_i    ( mst.r_last    ),
      .mst_r_id_i      ( mst.r_id      ),
      .mst_r_user_i    ( mst.r_user    ),
      .mst_r_ready_o   ( mst.r_ready   ),
      .mst_r_valid_i   ( mst.r_valid   ),
      .mst_b_resp_i    ( mst.b_resp    ),
      .mst_b_id_i      ( mst.b_id      ),
      .mst_b_user_i    ( mst.b_user    ),
      .mst_b_ready_o   ( mst.b_ready   ),
      .mst_b_valid_i   ( mst.b_valid   )
  );

endmodule
