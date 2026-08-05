// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.0 L2 package — geometry helpers and contention-oriented parameters.
// L2 is memory-side (AXI-to-AXI); never edits core L1 files.

package g6lc_l2_pkg;

  // Defaults tuned for router SoC: 256 KiB / 8-way / 64 B lines / 8 MSHR / 4 banks
  localparam int unsigned L2_DEFAULT_BYTE_SIZE   = 32'd262144;  // 256 KiB
  localparam int unsigned L2_DEFAULT_SET_ASSOC   = 32'd8;
  localparam int unsigned L2_DEFAULT_LINE_WIDTH  = 32'd512;     // 64 B (Zic64b)
  localparam int unsigned L2_DEFAULT_MSHR_DEPTH  = 32'd8;       // MLP under miss storms
  localparam int unsigned L2_DEFAULT_DATA_BANKS  = 32'd4;       // banked data for hit||fill

  function automatic int unsigned l2_num_sets(
      input int unsigned byte_size,
      input int unsigned set_assoc,
      input int unsigned line_width
  );
    return byte_size / (set_assoc * (line_width / 8));
  endfunction

  function automatic int unsigned l2_index_bits(input int unsigned num_sets);
    return (num_sets <= 1) ? 1 : $clog2(num_sets);
  endfunction

  function automatic int unsigned l2_offset_bits(input int unsigned line_width);
    return $clog2(line_width / 8);
  endfunction

  // AXI AxCACHE: OpenHW hpdcache_mem_to_axi encodes
  //   cacheable → BUFFERABLE|MODIFIABLE|RD_ALLOC|WR_ALLOC
  //   NC        → MODIFIABLE only (bit1 alone)
  // so "modifiable" alone is NOT sufficient — require an allocate bit too,
  // otherwise ROM/MMIO I$ fills enter the L2 miss path and hang on 64 B
  // line fills through axi2mem / prefetcher.
  function automatic logic l2_is_cacheable(input logic [3:0] ax_cache);
    return ax_cache[1] && (ax_cache[2] | ax_cache[3]);
  endfunction

endpackage
