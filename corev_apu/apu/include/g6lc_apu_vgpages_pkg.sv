// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Aperture page-allocator request/completion types (§7b of
// architecture/uncore/apu-vulkan-engine.md).  Page-granular arena over
// the blob SHM aperture window: ALLOC/FREE operate on whole PageBytes
// pages (the request `bytes` is rounded up internally); `base` is a
// window-relative byte offset.
package g6lc_apu_vgpages_pkg;

  typedef enum logic [2:0] {
    APU_VGPAGES_OP_ALLOC    = 3'd0,
    APU_VGPAGES_OP_FREE     = 3'd1,
    // reserve the caller-chosen extent (MAP_BLOB: the guest kernel owns
    // the SHM layout and dictates the window offset); the bitmap marks
    // every page the extent covers, so coverage may round up to whole
    // pages while `base` stays the exact byte offset
    APU_VGPAGES_OP_ALLOC_AT = 3'd2,
    // first-fit like ALLOC but inside the device-private arena above
    // the guest-visible window (descriptor-pool record stores; the
    // kernel's drm_mm can never pick it so no MAP_BLOB can collide)
    APU_VGPAGES_OP_ALLOC_PRIV = 3'd3,
    // §12.3 3d-d: top-down first-fit inside the guest window — the
    // highest-address run of ceil(bytes/PageBytes) pages — skipping any
    // candidate overlapping the byte exclusion [base, excl_hi)
    // (base == excl_hi = no exclusion).  Device-chosen extents placed
    // high stay clear of the kernel drm_mm's bottom-up choices, and
    // MAP_BLOB relocates them; the exclusion keeps an evicted squatter
    // out of the kernel's new extent.  Same status shape as ALLOC.
    APU_VGPAGES_OP_ALLOC_HI = 3'd4
  } apu_vgpages_op_e;

  typedef enum logic [1:0] {
    APU_VGPAGES_OK     = 2'd0,
    APU_VGPAGES_FULL   = 2'd1,
    APU_VGPAGES_BOUNDS = 2'd2,
    APU_VGPAGES_BUSY   = 2'd3   // ALLOC_AT extent overlaps a live alloc
  } apu_vgpages_status_e;

  typedef struct packed {
    apu_vgpages_op_e op;
    logic [31:0]     base;    // FREE base (window-relative byte offset);
                            // ALLOC_HI exclusion low [base, excl_hi)
    logic [31:0]     excl_hi; // ALLOC_HI exclusion high (== base: none)
    logic [31:0]     bytes;   // ALLOC/FREE length in bytes
  } apu_vgpages_req_t;

  typedef struct packed {
    apu_vgpages_status_e status;
    logic [31:0]         base;   // ALLOC result (window-relative byte off)
  } apu_vgpages_cpl_t;

endpackage
