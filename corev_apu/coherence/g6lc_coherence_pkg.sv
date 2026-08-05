// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.2 multi-core coherence package — line-aligned invalidation types and
// helpers for 1..CVA6_MAX_CORES. Inclusive WT L2 + write-invalidate path.

package g6lc_coherence_pkg;

  // Default line size matches Zic64b / L2 default (64 B)
  localparam int unsigned COH_DEFAULT_LINE_BYTES = 64;
  localparam int unsigned COH_DEFAULT_SF_ENTRIES = 128;
  localparam int unsigned COH_DEFAULT_INVAL_DEPTH = 4;

  // Compact invalidation command (OpenPiton L15-style fields)
  typedef struct packed {
    logic        valid;       // pulse/level: inv request present
    logic        all_ways;    // full-cache invalidate (fence.i / flush)
    logic        dcache;      // target D$
    logic        icache;      // target I$
    logic [55:0] line_addr;   // physical line base (addr >> log2(line_bytes))
  } coh_inval_t;

  function automatic logic [55:0] coh_line_tag(
      input logic [63:0] addr,
      input int unsigned line_bytes
  );
    // Variable shift (not [63:off]) — Verilator requires constant part-selects.
    int unsigned off;
    logic [63:0] shifted;
    off = $clog2(line_bytes);
    shifted = addr >> off;
    return shifted[55:0];
  endfunction

  function automatic logic [63:0] coh_line_base(
      input logic [55:0] line_addr,
      input int unsigned line_bytes
  );
    int unsigned off;
    logic [63:0] base;
    off = $clog2(line_bytes);
    // Variable shift instead of non-constant replication {off{1'b0}}.
    base = {8'b0, line_addr};
    return base << off;
  endfunction

endpackage
