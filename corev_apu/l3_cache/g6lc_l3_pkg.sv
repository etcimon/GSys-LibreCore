// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U5/U6 memory hierarchy — L3 package (reuses L2 geometry helpers).
// L3 is memory-side below L2; never edits core L1.

package g6lc_l3_pkg;
  import g6lc_l2_pkg::*;

  // Server-class defaults: 2 MiB / 16-way / 64 B / 16 MSHR / 8 banks
  localparam int unsigned L3_DEFAULT_BYTE_SIZE  = 32'd2097152;
  localparam int unsigned L3_DEFAULT_SET_ASSOC  = 32'd16;
  localparam int unsigned L3_DEFAULT_LINE_WIDTH = 32'd512;
  localparam int unsigned L3_DEFAULT_MSHR_DEPTH = 32'd16;
  localparam int unsigned L3_DEFAULT_DATA_BANKS = 32'd8;

  // Re-export L2 helpers under L3 names for clarity
  function automatic int unsigned l3_num_sets(
      input int unsigned byte_size,
      input int unsigned set_assoc,
      input int unsigned line_width
  );
    return l2_num_sets(byte_size, set_assoc, line_width);
  endfunction

endpackage
