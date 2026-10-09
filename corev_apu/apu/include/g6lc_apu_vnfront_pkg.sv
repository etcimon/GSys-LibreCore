// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Front-end sequencer constants (hand-written; §4c/§6 of
// architecture/uncore/apu-vulkan-engine.md).  VkResult values the
// sequencer reports back through the reply, and the CMDBUF lifecycle
// bit positions kept in the object's ObjTab `state` word.
package g6lc_apu_vnfront_pkg;

  localparam logic [31:0] APU_VK_SUCCESS               = 32'h0000_0000;
  localparam logic [31:0] APU_VK_NOT_READY             = 32'h0000_0001;
  localparam logic [31:0] APU_VK_ERROR_OUT_OF_DEVICE_MEMORY =
                                                        32'hFFFF_FFFE;
  localparam logic [31:0] APU_VK_ERROR_DEVICE_LOST     = 32'hFFFF_FFFC;
  localparam logic [31:0] APU_VK_ERROR_FEATURE_NOT_PRESENT =
                                                        32'hFFFF_FFF8;
  localparam logic [31:0] APU_VK_ERROR_UNKNOWN         = 32'hFFFF_FFF3;
  // 3d-b: VkResult -1000072003 — refused external-memory handle types
  localparam logic [31:0] APU_VK_ERROR_INVALID_EXTERNAL_HANDLE =
                                                        32'hC464_1CBD;
  // 3d-b: VkResult -11 — format/tiling combo not in the profile
  localparam logic [31:0] APU_VK_ERROR_FORMAT_NOT_SUPPORTED =
                                                        32'hFFFF_FFF5;

  // CMDBUF lifecycle bits in the ObjTab entry state word
  localparam logic [31:0] APU_CB_RECORDING  = 32'h1;
  localparam logic [31:0] APU_CB_EXECUTABLE = 32'h2;
  localparam logic [31:0] APU_CB_PENDING    = 32'h4;
  localparam logic [31:0] APU_CB_INVALID    = 32'h8;
  localparam logic [31:0] APU_CB_STATE_MASK = 32'hF;

  // §12.3 F5 descriptor objects (memory-resident records; record
  // format + row packing in g6lc_apu_sh_pkg).
  localparam logic [31:0] APU_VK_ERROR_OUT_OF_POOL_MEMORY =
                                                        32'hFFFF_FFFB;
  // DESCRIPTOR_POOL entry:
  //   aux[31:0]   aperture byte base of the record store (vgpages)
  //   aux[43:32]  bump — records handed out, 32-byte units (bump
  //               allocation; reset/destroy return it wholesale)
  //   aux[63:44]  nsets — sets minted from the pool
  //   size[31:0]  record-store byte capacity (Σ descriptorCount×32)
  //   state[31:16] maxSets;  state[15:0] epoch — ++ on
  //               vkResetDescriptorPool; sets minted under an older
  //               epoch are dead at dispatch
  // DESCRIPTOR_SET entry:
  //   aux[31:0]   {poison[31], ndyn[30:25], set_base[24:0]} —
  //               aperture byte base of the set's record table
  //   aux[63:32]  layout handle {gen,slot} minted at allocate time
  //   size[31:0]  pool handle {gen,slot} (destroy/reset detection)
  //   state[15:0] pool epoch sampled at allocate time
  // DESCRIPTOR_SET_LAYOUT entry (ObjPay payload of 1+2*nbind words):
  //   word0       = {pad[31:16], nbind[15:0]}
  //   rows        = apu_sh_bindrow_t packing (2 words each)
  //   aux[63:32]  = {payload base, payload words}
  //   aux[31:16]  = ndyn — dynamic descriptor elements in the layout
  //   aux[15:0]   = set_bytes — the set's record-table extent

endpackage
