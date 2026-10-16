// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Object-payload store request/completion types (§7b of
// architecture/uncore/apu-vulkan-engine.md).  Word-addressed payload
// arena: ALLOC/FREE operate on whole ChunkWords chunks (the request
// `words` is in payload words, rounded up internally); WRITE/READ
// address single payload words.
package g6lc_apu_objpay_pkg;

  // §5a G3b-i: the payload arena is chunked at 64 words (256 B) and
  // object aux fields park an extent's base in CHUNK units —
  // aux[63:32] = {base>>6 [15:0], words[15:0]} — so 2^16 chunks reach
  // the full 16 MiB PayMem.  Every unpark site shifts the chunk base
  // back to a word address by APU_OBJPAY_CHUNK_SHIFT.
  localparam int unsigned APU_OBJPAY_CHUNK_WORDS = 64;
  localparam int unsigned APU_OBJPAY_CHUNK_SHIFT = 6;
  // ALLOC refuses words above the parked 16-bit words field.
  localparam int unsigned APU_OBJPAY_MAX_WORDS   = 65535;

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
