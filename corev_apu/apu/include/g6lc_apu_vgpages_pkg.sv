// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Aperture page-allocator request/completion types (§7b of
// architecture/uncore/apu-vulkan-engine.md).  Page-granular arena over
// the blob SHM aperture window: ALLOC/FREE operate on whole PageBytes
// pages (the request `bytes` is rounded up internally); `base` is a
// window-relative byte offset.
package g6lc_apu_vgpages_pkg;

  typedef enum logic [1:0] {
    APU_VGPAGES_OP_ALLOC = 2'd0,
    APU_VGPAGES_OP_FREE  = 2'd1
  } apu_vgpages_op_e;

  typedef enum logic [1:0] {
    APU_VGPAGES_OK     = 2'd0,
    APU_VGPAGES_FULL   = 2'd1,
    APU_VGPAGES_BOUNDS = 2'd2
  } apu_vgpages_status_e;

  typedef struct packed {
    apu_vgpages_op_e op;
    logic [31:0]     base;   // FREE base (window-relative byte offset)
    logic [31:0]     bytes;  // ALLOC/FREE length in bytes
  } apu_vgpages_req_t;

  typedef struct packed {
    apu_vgpages_status_e status;
    logic [31:0]         base;   // ALLOC result (window-relative byte off)
  } apu_vgpages_cpl_t;

endpackage
