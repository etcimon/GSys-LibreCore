// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Object-payload store request/completion types (§7b of
// architecture/uncore/apu-vulkan-engine.md).  Word-addressed payload
// arena: ALLOC/FREE operate on whole ChunkWords chunks (the request
// `words` is in payload words, rounded up internally); WRITE/READ
// address single payload words.
package g6lc_apu_objpay_pkg;

  typedef enum logic [2:0] {
    APU_OBJPAY_OP_ALLOC = 3'd0,
    APU_OBJPAY_OP_FREE  = 3'd1,
    APU_OBJPAY_OP_WRITE = 3'd2,
    APU_OBJPAY_OP_READ  = 3'd3
  } apu_objpay_op_e;

  typedef enum logic [2:0] {
    APU_OBJPAY_OK     = 3'd0,
    APU_OBJPAY_FULL   = 3'd1,
    APU_OBJPAY_BOUNDS = 3'd2
  } apu_objpay_status_e;

  typedef struct packed {
    apu_objpay_op_e op;
    logic [31:0]    addr;    // FREE base / WRITE/READ word address
    logic [31:0]    words;   // ALLOC/FREE length in payload words
    logic [31:0]    wdata;   // WRITE data
  } apu_objpay_req_t;

  typedef struct packed {
    apu_objpay_status_e status;
    logic [31:0]        base;   // ALLOC result (word address)
    logic [31:0]        rdata;  // READ result
  } apu_objpay_cpl_t;

endpackage
