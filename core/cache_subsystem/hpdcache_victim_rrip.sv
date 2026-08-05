/*
 *  Copyright 2026 Etienne Cimon
 *  SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
 *
 *  U3: HPDcache victim selection via SRRIP/DRRIP (wraps g6lc_rrip_repl).
 */
module hpdcache_victim_rrip
import hpdcache_pkg::*;
#(
    parameter hpdcache_cfg_t HPDcacheCfg = '0,
    parameter bit DRRIP_EN = 1'b0,

    localparam type set_t        = logic [$clog2(HPDcacheCfg.u.sets)-1:0],
    localparam type way_vector_t = logic [HPDcacheCfg.u.ways-1:0]
) (
    input  logic                  clk_i,
    input  logic                  rst_ni,

    input  logic                  updt_i,
    input  set_t                  updt_set_i,
    input  way_vector_t           updt_way_i,

    input  logic                  sel_victim_i,
    input  way_vector_t           sel_dir_valid_i,
    input  way_vector_t           sel_dir_wback_i,
    input  way_vector_t           sel_dir_dirty_i,
    input  way_vector_t           sel_dir_fetch_i,
    input  set_t                  sel_victim_set_i,
    output way_vector_t           sel_victim_way_o
);

    // Eligible victims: valid and not mid-fetch (same priority classing as PLRU)
    way_vector_t eligible;
    assign eligible = sel_dir_valid_i & ~sel_dir_fetch_i;

    // Prefer free (invalid) ways first — fill empty slots before RRIP eviction
    way_vector_t unused_ways;
    logic        unused_available;
    way_vector_t unused_victim;
    assign unused_ways = ~sel_dir_fetch_i & ~sel_dir_valid_i;
    assign unused_available = |unused_ways;

    hpdcache_prio_1hot_encoder #(.N(HPDcacheCfg.u.ways))
        unused_select_i (
            .val_i (unused_ways),
            .val_o (unused_victim)
        );

    way_vector_t rrip_victim;
    g6lc_rrip_repl #(
        .NR_SETS   (HPDcacheCfg.u.sets),
        .NR_WAYS   (HPDcacheCfg.u.ways),
        .RRPV_BITS (2),
        .DRRIP_EN  (DRRIP_EN)
    ) i_rrip (
        .clk_i,
        .rst_ni,
        .updt_i,
        .updt_set_i,
        .updt_way_i,
        .sel_i      (sel_victim_i & ~unused_available),
        .sel_valid_i(eligible),
        .sel_set_i  (sel_victim_set_i),
        .sel_way_o  (rrip_victim),
        // On selection of a free way we still "fill" it with long RRPV
        .fill_i     (sel_victim_i),
        .fill_set_i (sel_victim_set_i),
        .fill_way_i (unused_available ? unused_victim : rrip_victim)
    );

    assign sel_victim_way_o = unused_available ? unused_victim : rrip_victim;

endmodule
