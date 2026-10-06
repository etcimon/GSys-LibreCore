// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Submit-time executor types (hand-written; §6 of
// architecture/uncore/apu-vulkan-engine.md).
//
// A submit entry names up to four command buffers by their cmdrec
// arena index and their ObjTab generational handle {gen,slot} (the
// executor PINs/UNPINs the handle around execution).  Records are
// pulled from cmdrec, every stored handle re-resolved through ObjTab
// (a stale generation loses the submission), and work records are
// issued on the work port with a snapshot of the executor's state
// registers.
package g6lc_apu_cmdexec_pkg;

  import g6lc_apu_cmdrec_pkg::apu_cmdrec_rec_t;

  typedef enum logic [1:0] {
    APU_CMDEXEC_CLS_NOP      = 2'd0,
    APU_CMDEXEC_CLS_STATE    = 2'd1,
    APU_CMDEXEC_CLS_WORK     = 2'd2,
    APU_CMDEXEC_CLS_BARRIER  = 2'd3
  } apu_cmdexec_cls_e;

  typedef struct packed {
    logic [4:0]      fence_idx;         // fence slot, 31 = none
    logic [2:0]      nbufs;             // buffers in this submit (1..4)
    logic [3:0][7:0] crec;              // cmdrec buffer indices
    logic [3:0][31:0] chndl;            // objtab {gen,slot} handles
  } apu_cmdexec_submit_t;

  // executor state registers, snapshotted into every work record
  typedef struct packed {
    logic [31:0]        pipeline;       // bound pipeline {gen,slot}
    logic [3:0][31:0]   dset;           // §7b: bound descriptor sets
    logic [31:0]        ibo;            // bound index buffer
    logic [31:0]        vtx;            // first bound vertex buffer
    logic [31:0]        vp;             // first viewport imm word
    logic [31:0]        sc;             // first scissor imm word
    logic [15:0]        push;           // push-constant stageFlags word
    logic [15:0]        push_base;      // §7b: cmdrec arena base of the
                                        // last vkCmdPushConstants payload
    logic [15:0]        push_len;       // §7b: its byte size
    logic               rp_active;
    logic [3:0]         subpass;
  } apu_cmdexec_state_t;

  typedef struct packed {
    logic [31:0]        ctype;
    apu_cmdexec_state_t snap;
    apu_cmdrec_rec_t    rec;
  } apu_cmdexec_work_t;

  // §12.3 C/5a: Xfer operand descriptor, resolved by the executor's
  // XFER sub-assembly (buffer LOOKUP + bound-memory READSLOT) and valid
  // alongside work_o while the work record is a CopyBuffer/FillBuffer/
  // UpdateBuffer.  All bases are aperture-relative byte offsets; sizes
  // are the operand's effective extent (min(buffer.size, mem.size-off)).
  // The U64 operands (copy regions, dstOffset/size, update data) ride
  // the cmdrec payload arena; the engine replays them via PAYREAD.
  typedef enum logic [1:0] {
    APU_XFER_OP_COPY   = 2'd0,
    APU_XFER_OP_FILL   = 2'd1,
    APU_XFER_OP_UPDATE = 2'd2
  } apu_xfer_op_e;

  typedef struct packed {
    apu_xfer_op_e    op;
    logic [7:0]      cbuf;      // cmdrec arena owner buffer
    logic [15:0]     pay_base;  // arena word base (rec.imm[7])
    logic [15:0]     regions;   // COPY: regionCount (rec.imm[0])
    logic [31:0]     src_base;  // COPY: src buffer aperture offset
    logic [31:0]     src_size;  // COPY: src operand extent (bytes)
    logic [31:0]     dst_base;  // dst buffer aperture offset
    logic [31:0]     dst_size;  // dst operand extent (bytes)
  } apu_xfer_desc_t;

  // per-fence completion status for the WAIT class
  typedef enum logic [1:0] {
    APU_CMDEXEC_FENCE_PENDING     = 2'd0,
    APU_CMDEXEC_FENCE_OK          = 2'd1,
    APU_CMDEXEC_FENCE_DEVICE_LOST = 2'd2
  } apu_cmdexec_fence_e;

endpackage
