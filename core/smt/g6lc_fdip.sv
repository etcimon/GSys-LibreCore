// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Versions of this file released before 2026-08-05 were additionally available
// under Apache-2.0 WITH SHL-2.1; that grant is irrevocable for those versions.
//
// U2 FDIP: walk FTQ entries ahead of demand fetch and emit droppable I$
// prefetches. Hard invariants:
//   - demand always wins the shared I$ port
//   - never prefetch non-idempotent / non-execute PMA regions
//   - never raise architecturally visible exceptions (TLB miss ΓåÆ drop)
//   - prefetches assert .spec

module g6lc_fdip
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned DISTANCE = 2
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic                    enable_i,
    // FTQ peek
    input  logic                    peek_valid_i,
    input  logic [CVA6Cfg.VLEN-1:0] peek_vaddr_i,
    // Demand owns the bus this cycle
    input  logic                    demand_active_i,
    // I$ ready for a new request
    input  logic                    icache_ready_i,
    // Prefetch issue (only when !demand_active_i)
    output logic                    pf_req_o,
    output logic [CVA6Cfg.VLEN-1:0] pf_vaddr_o,
    // Observability
    output logic                    pf_drop_pma_o
);

  logic pma_ok;
  logic [63:0] addr64;

  assign addr64 = {{(64 - CVA6Cfg.VLEN) {1'b0}}, peek_vaddr_i};
  // Execute region AND not non-idempotent (MMIO)
  assign pma_ok = config_pkg::is_inside_execute_regions(CVA6Cfg, addr64) &&
                  !config_pkg::is_inside_nonidempotent_regions(CVA6Cfg, addr64);

  assign pf_drop_pma_o = enable_i && peek_valid_i && !pma_ok;
  assign pf_req_o = enable_i && peek_valid_i && pma_ok &&
                    !demand_active_i && icache_ready_i && !flush_i;
  assign pf_vaddr_o = peek_vaddr_i;

endmodule
