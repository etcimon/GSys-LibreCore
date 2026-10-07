// SYNTHETIC FIXTURE. Invented content (see ../README.md).
// SPDX-License-Identifier: MIT
//
// Minimal APU shared-memory constants for the bridge-ingest test. Shaped like
// the real g6lc_apu_pkg.sv; the aperture address is invented.

package g6lc_apu_pkg;

  localparam logic [31:0] APU_SHM_ID_HOST_VISIBLE = 32'd3;
  localparam logic [63:0] APU_SHM_BASE            = 64'h0000_0000_8400_0000;
  localparam logic [63:0] APU_SHM_BYTES           = 64'h0000_0000_0020_0000;

endpackage
