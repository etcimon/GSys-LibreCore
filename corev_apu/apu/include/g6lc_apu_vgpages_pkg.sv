// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Aperture page-allocator request/completion types (§7b of
// architecture/uncore/apu-vulkan-engine.md).  Page-granular arena over
// the blob SHM aperture window: ALLOC/FREE operate on whole PageBytes
// pages (the request `bytes` is rounded up internally); `base` is a
// window-relative byte offset.
package g6lc_apu_vgpages_pkg;

  typedef enum logic [1:0] {
    APU_VGPAGES_OP_ALLOC    = 2'd0,
    APU_VGPAGES_OP_FREE     = 2'd1,
    // reserve the caller-chosen extent (MAP_BLOB: the guest kernel owns
    // the SHM layout and dictates the window offset); the bitmap marks
    // every page the extent covers, so coverage may round up to whole
    // pages while `base` stays the exact byte offset
    APU_VGPAGES_OP_ALLOC_AT = 2'd2,
    // first-fit like ALLOC but inside the device-private arena above
    // the guest-visible window (descriptor-pool record stores; the
    // kernel's drm_mm can never pick it so no MAP_BLOB can collide)
    APU_VGPAGES_OP_ALLOC_PRIV = 2'd3
  } apu_vgpages_op_e;

  typedef enum logic [1:0] {
    APU_VGPAGES_OK     = 2'd0,
    APU_VGPAGES_FULL   = 2'd1,
    APU_VGPAGES_BOUNDS = 2'd2,
    APU_VGPAGES_BUSY   = 2'd3   // ALLOC_AT extent overlaps a live alloc
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
