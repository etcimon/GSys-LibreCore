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

endpackage
