// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Za64rs reservation-set membership. The architectural set used by Zalrsc
// must be contiguous, naturally aligned, and at most 64 bytes. The live
// exclusive monitor (corev_apu/src/g6lc_axi_lrsc.sv) keys on exact AXI
// address; that is a 1-address set, which is a legal Za64rs set. This leaf
// is the same compare plus the advertise-ready predicate (RVA and a D$
// line of at most 64 B, so invalidation cannot grow the set past 64 B).
//
// Off-config: exact match still, za64rs_ok_o = 0.
// Do not widen the compare to a 64 B mask: adjacent OpenSBI/Linux locks
// on different addresses must keep independent reservations.

module g6lc_za64rs #(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter int unsigned ADDR_WIDTH = 64
) (
    input  logic [ADDR_WIDTH-1:0] lr_addr_i,
    input  logic [ADDR_WIDTH-1:0] other_addr_i,
    output logic                  same_set_o,
    output logic                  within_max_o,
    output logic                  za64rs_ok_o
);

  localparam int unsigned MAX_SHIFT = 6;  // 64 B

  assign same_set_o = (lr_addr_i == other_addr_i);
  assign within_max_o = (lr_addr_i[ADDR_WIDTH-1:MAX_SHIFT] ==
                         other_addr_i[ADDR_WIDTH-1:MAX_SHIFT]);
  assign za64rs_ok_o = CVA6Cfg.RVZa64rs && CVA6Cfg.RVA &&
                       (CVA6Cfg.DCACHE_LINE_WIDTH != 0) &&
                       (CVA6Cfg.DCACHE_LINE_WIDTH <= 512);

  // pragma translate_off
  always_comb begin
    if (CVA6Cfg.RVZa64rs && same_set_o && !within_max_o)
      $error("g6lc_za64rs: reservation set exceeds 64 bytes");
  end
  // pragma translate_on

endmodule
