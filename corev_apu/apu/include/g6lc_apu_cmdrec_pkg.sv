// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Command-record request/completion types (hand-written; §5a G3b-iii +
// §6 of architecture/uncore/apu-vulkan-engine.md).
//
// apu_cmdrec_rec_t is the resolved decode stored in the record chain:
// the command type (VkCommandTypeEXT), flags, the ObjTab generational
// handle {gen[15:0], slot[15:0]} and object kind of the first four
// handle slots, and the first eight immediate words.  The executor
// dispatches on `type` and re-resolves each handle through ObjTab so a
// stale generation is detected at submit time.  A record is one
// 16-word (512-bit) ObjPay line: rows 1..63 of a CbChunkWords chunk.
//
// G3b-iii: command buffers live entirely in PayMem.  Per-buffer state
// is a 64-word descriptor block parked in the object's aux[63:32];
// the request's `cbd` is its word address.  Records chain 1024-word
// chunks (w0 = next), record payloads chain identically with bump
// allocation and imm[7] carrying the payload's absolute word address.
package g6lc_apu_cmdrec_pkg;

  typedef enum logic [3:0] {
    APU_CMDREC_OP_BEGIN        = 4'd0,
    APU_CMDREC_OP_APPEND       = 4'd1,
    APU_CMDREC_OP_END          = 4'd2,
    APU_CMDREC_OP_RESET        = 4'd3,
    APU_CMDREC_OP_READ         = 4'd4,
    APU_CMDREC_OP_COUNT        = 4'd5,
    // walk the pool chain parked in the command pool's aux[63:32]:
    // one SWEEP interim completion per buffer (pdata = its w9
    // handle), final OK; DESTROY also frees each descriptor block
    APU_CMDREC_OP_RESET_POOL   = 4'd6,
    APU_CMDREC_OP_DESTROY_POOL = 4'd7
  } apu_cmdrec_op_e;

  typedef enum logic [3:0] {
    APU_CMDREC_OK            = 4'd0,
    APU_CMDREC_FULL          = 4'd1,   // ObjPay ALLOC failed
    APU_CMDREC_NOT_RECORDING = 4'd2,
    APU_CMDREC_NOT_SEALED    = 4'd3,
    APU_CMDREC_BAD_IDX       = 4'd4,
    APU_CMDREC_BAD_BUF       = 4'd5,
    APU_CMDREC_PAY_FULL      = 4'd6,
    APU_CMDREC_SWEEP         = 4'd7    // RESET_POOL/destroy interim
  } apu_cmdrec_status_e;

  typedef struct packed {
    logic [31:0]      ctype;    // VkCommandTypeEXT of the vkCmd*
    logic [31:0]      flags;
    logic [3:0][31:0] handle;   // {gen[15:0], slot[15:0]}; 0 = none
    logic [3:0][7:0]  kind;     // APU_VN_KIND_* per handle
    logic [7:0][31:0] imm;
    logic [31:0]      spare;    // reserved, kept at 0 by writers
  } apu_cmdrec_rec_t;           // 512 bits = 16 words

  // descriptor block (64 words): w0 flags {recording, sealed,
  // secondary, one_time, simultaneous, rp_continue}, w1 count,
  // w2 rec_head, w3 rec_tail, w4 row, w5 pay_head, w6 pay_tail,
  // w7 pay_top, w8 pool handle, w9 own handle, w10 pool_prev,
  // w11 pool_next, w12..63 reserved.  cmdrec owns w0..w7 through its
  // write-back cache; vnfront owns w8..w11 via direct ObjPay writes.
  localparam int unsigned APU_CBD_W0     = 0;
  localparam int unsigned APU_CBD_COUNT  = 1;
  localparam int unsigned APU_CBD_RECH   = 2;
  localparam int unsigned APU_CBD_RECT   = 3;
  localparam int unsigned APU_CBD_ROW    = 4;
  localparam int unsigned APU_CBD_PAYH   = 5;
  localparam int unsigned APU_CBD_PAYT   = 6;
  localparam int unsigned APU_CBD_PTOP   = 7;
  localparam int unsigned APU_CBD_POOL   = 8;
  localparam int unsigned APU_CBD_OWN    = 9;
  localparam int unsigned APU_CBD_PPREV  = 10;
  localparam int unsigned APU_CBD_PNEXT  = 11;
  // w0 flag bits
  localparam int unsigned APU_CBF_RECORDING = 0;
  localparam int unsigned APU_CBF_SEALED    = 1;
  localparam int unsigned APU_CBF_SECONDARY = 2;
  localparam int unsigned APU_CBF_ONE_TIME  = 3;
  localparam int unsigned APU_CBF_SIMULT    = 4;
  localparam int unsigned APU_CBF_RP_CONT   = 5;
  // record/payload chain geometry (§5a): 1024-word chunks, w0 = next
  localparam int unsigned APU_CB_CHUNK_WORDS = 1024;
  localparam int unsigned APU_CB_REC_FIRST   = 16;   // row 1 base
  localparam int unsigned APU_CB_REC_ROWS    = 63;
  localparam int unsigned APU_CBD_WORDS      = 64;

  typedef struct packed {
    apu_cmdrec_op_e  op;
    logic [31:0]     cbd;       // descriptor word address (chunk-
                                // aligned; pool ops: head cbd)
    logic [15:0]     idx;       // READ: record index
    logic [15:0]     pay_n;     // APPEND: payload words to stream
    logic [31:0]     flags;     // BEGIN: usage bits {one_time,
                                // simultaneous, rp_continue}
    apu_cmdrec_rec_t rec;       // APPEND payload
  } apu_cmdrec_req_t;

  typedef struct packed {
    apu_cmdrec_status_e status;
    logic [31:0]        count;  // COUNT result / current fill
    logic [31:0]        pdata;  // SWEEP interim: buffer's w9 handle
    apu_cmdrec_rec_t    rec;    // READ result
  } apu_cmdrec_cpl_t;

endpackage
