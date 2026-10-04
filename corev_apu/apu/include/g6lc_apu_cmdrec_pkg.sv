// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Command-record request/completion types (hand-written; §6 of
// architecture/uncore/apu-vulkan-engine.md).
//
// apu_cmdrec_rec_t is the resolved decode stored in the record arena:
// the command type (VkCommandTypeEXT), flags, the ObjTab generational
// handle {gen[15:0], slot[15:0]} and object kind of the first four
// handle slots, and the first eight immediate words.  The executor
// dispatches on `type` and re-resolves each handle through ObjTab so a
// stale generation is detected at submit time.  The record occupies a
// fixed 16-word (512-bit) SRAM row; unused low handles are 0 and the
// tail word is reserved.
package g6lc_apu_cmdrec_pkg;

  typedef enum logic [3:0] {
    APU_CMDREC_OP_BEGIN  = 4'd0,
    APU_CMDREC_OP_APPEND = 4'd1,
    APU_CMDREC_OP_END    = 4'd2,
    APU_CMDREC_OP_RESET  = 4'd3,
    APU_CMDREC_OP_READ   = 4'd4,
    APU_CMDREC_OP_COUNT  = 4'd5
  } apu_cmdrec_op_e;

  typedef enum logic [3:0] {
    APU_CMDREC_OK            = 4'd0,
    APU_CMDREC_FULL          = 4'd1,
    APU_CMDREC_NOT_RECORDING = 4'd2,
    APU_CMDREC_NOT_SEALED    = 4'd3,
    APU_CMDREC_BAD_IDX       = 4'd4,
    APU_CMDREC_BAD_BUF       = 4'd5
  } apu_cmdrec_status_e;

  typedef struct packed {
    logic [31:0]      ctype;    // VkCommandTypeEXT of the vkCmd*
    logic [31:0]      flags;
    logic [3:0][31:0] handle;   // {gen[15:0], slot[15:0]}; 0 = none
    logic [3:0][7:0]  kind;     // APU_VN_KIND_* per handle
    logic [7:0][31:0] imm;
    logic [31:0]      spare;    // reserved, kept at 0 by writers
  } apu_cmdrec_rec_t;           // 512 bits = 16 words

  typedef struct packed {
    apu_cmdrec_op_e  op;
    logic [7:0]      cbuf;       // command-buffer record index
    logic [7:0]      idx;       // READ: record index within cbuf
    apu_cmdrec_rec_t rec;       // APPEND payload
  } apu_cmdrec_req_t;

  typedef struct packed {
    apu_cmdrec_status_e status;
    logic [7:0]         count;  // COUNT result / current fill
    apu_cmdrec_rec_t    rec;    // READ result
  } apu_cmdrec_cpl_t;

endpackage
