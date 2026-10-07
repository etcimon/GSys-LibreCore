// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Shared types for the virtio-gpu transport path (§6b of
// architecture/uncore/apu-vulkan-engine.md): the descriptor-chain
// element vgctl consumes, the UAPI opcode/response/blob constants the
// control processor answers with, and the Venus ring status bits the
// pump publishes through the shared-memory window.
//
// The UAPI values come from the pinned Resolute kernel
// include/uapi/linux/virtio_gpu.h; the ring status bits are Mesa's
// vn_ring (VNRING_*), which the driver polls on.

package g6lc_apu_vg_pkg;

  // One virtqueue descriptor element for the control chain: {addr,
  // len, write}.  n_desc <= 4 per chain element.
  typedef struct packed {
    logic [63:0] addr;
    logic [31:0] len;
    logic        write;
    logic [30:0] pad;
  } apu_vg_desc_t;

  localparam int unsigned APU_VG_MAX_DESC = 4;

  // Guest-physical base/extent of the Venus shared-memory window the
  // aperture allocator carves into pages.  Must equal the
  // virtio-mmio ShmEn SHM id 1 (HOST_VISIBLE) window published by
  // g6lc_apu_virtio_mmio (APU_SHM_BASE/APU_SHM_BYTES); kept local so
  // the vg engines do not depend on g6lc_apu_pkg.  The guest kernel's
  // shm drm_mm packs MAP_BLOB offsets at guest-page (4 KiB) density, so
  // the allocator bitmap tracks 4 KiB pages — 8192 flops for 32 MiB.
  localparam logic [63:0] APU_VG_SHM_BASE  = 64'h8200_0000;
  localparam logic [63:0] APU_VG_SHM_BYTES = 64'h0200_0000;
  localparam int unsigned APU_VG_PAGES     = 8192;
  localparam int unsigned APU_VG_PAGE_BYTES =
      32'(APU_VG_SHM_BYTES / APU_VG_PAGES);
  // aperture word-address width (aperture-relative byte offset >> 2)
  localparam int unsigned APU_VG_AP_WORD_W = $clog2(32'(APU_VG_SHM_BYTES / 4));

  // ---- virtio_gpu_ctrl_type / response types (UAPI) ----------------
  // UAPI enum order: 0x0107 is RESOURCE_DETACH_BACKING; the capset
  // commands follow it (GET_CAPSET_INFO 0x0108, GET_CAPSET 0x0109).
  localparam logic [31:0] APU_VG_GET_CAPSET_INFO   = 32'h0108;
  localparam logic [31:0] APU_VG_GET_CAPSET        = 32'h0109;
  localparam logic [31:0] APU_VG_CTX_CREATE        = 32'h0200;
  localparam logic [31:0] APU_VG_CTX_DESTROY       = 32'h0201;
  localparam logic [31:0] APU_VG_CTX_ATTACH        = 32'h0202;
  localparam logic [31:0] APU_VG_CTX_DETACH        = 32'h0203;
  localparam logic [31:0] APU_VG_SUBMIT_3D         = 32'h0207;
  localparam logic [31:0] APU_VG_MAP_BLOB          = 32'h0208;
  localparam logic [31:0] APU_VG_UNMAP_BLOB        = 32'h0209;
  localparam logic [31:0] APU_VG_CREATE_BLOB       = 32'h010C;
  localparam logic [31:0] APU_VG_UNREF             = 32'h0102;

  localparam logic [31:0] APU_VG_RESP_NODATA       = 32'h1100;
  localparam logic [31:0] APU_VG_RESP_CAPSET_INFO  = 32'h1102;
  localparam logic [31:0] APU_VG_RESP_CAPSET       = 32'h1103;
  localparam logic [31:0] APU_VG_RESP_MAP_INFO     = 32'h1106;
  localparam logic [31:0] APU_VG_ERR_UNSPEC        = 32'h1200;
  localparam logic [31:0] APU_VG_ERR_RID           = 32'h1203;
  localparam logic [31:0] APU_VG_ERR_CID           = 32'h1204;
  localparam logic [31:0] APU_VG_ERR_PARAM         = 32'h1205;

  localparam logic [31:0] APU_VG_FLAG_FENCE        = 32'h01;
  localparam logic [31:0] APU_VG_CAPSET_VENUS      = 32'd4;
  localparam logic [31:0] APU_VG_BLOB_HOST3D       = 32'h0002;
  localparam logic [31:0] APU_VG_BLOB_MAPPABLE     = 32'h0001;
  localparam logic [31:0] APU_VG_MAP_WC            = 32'd3;  // VIRTIO_GPU_MAP_CACHE_WC
  localparam logic [31:0] APU_VG_CTX_INIT_MASK     = 32'h000000ff;

  // ---- Venus ring status bits (vn_ring.h) ---------------------------
  localparam logic [31:0] APU_VNRING_IDLE  = 32'h1;
  localparam logic [31:0] APU_VNRING_FATAL = 32'h2;
  localparam logic [31:0] APU_VNRING_ALIVE = 32'h4;

  // ObjTab id tagging: ObjTab resolves a req.id with a zero high word
  // as a {gen,slot} handle, so transport resource/context ids (small
  // u32s) must be tagged into the directory-id space before lookup.
  localparam logic [63:0] APU_VG_ID_TAG = 64'h0000_0001_0000_0000;

endpackage
