// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// Generational object table request/completion types (hand-written; the
// generated Venus tables live in g6lc_apu_vn_pkg).
//
// Addressing convention: single-object ops take `id[63:0]`.  When
// `id[63:32] != 0` the id is a driver-visible object id resolved through
// the hash directory.  When `id[63:32] == 0` the low 32 bits are a
// generational handle `{gen[15:0], slot[15:0]}` resolved directly against
// the entry SRAM; a stale generation reports GEN.  A live generation is
// never 0, so `id[63:32] == 0 && id[31:16] == 0` is also resolved as a
// driver id through the directory — real client ids are tagged into a
// reserved high-word namespace (below) rather than passed raw: Mesa
// Venus mints dense small-integer ids (`vn_get_next_obj_id`), so an
// untagged client id could alias the handle form.
//
// Id namespaces (id[63:32] discriminant):
//   64'h0000_0002_0000_0000 | id   — Vulkan client object ids
//                                    (vnfront, plus vgctl's memory-id
//                                    lookups of DEVICE_MEMORY objects)
//   64'h0000_0001_0000_0000 | id   — virtio-gpu resource/context ids
//                                    (APU_VG_ID_TAG, g6lc_apu_vg_pkg)
// Both are disjoint for client/resource ids below 2^32, which covers
// every id the stock driver can mint.
//
// For RESET_CTX the completion `handle[15:0]` carries the number of
// objects that remained pinned in the context.

package g6lc_apu_objtab_pkg;

  typedef enum logic [3:0] {
    APU_OBJTAB_OP_ALLOC     = 4'd0,
    APU_OBJTAB_OP_LOOKUP    = 4'd1,
    APU_OBJTAB_OP_RETIRE    = 4'd2,
    APU_OBJTAB_OP_PIN       = 4'd3,
    APU_OBJTAB_OP_UNPIN     = 4'd4,
    APU_OBJTAB_OP_SETSTATE  = 4'd5,
    APU_OBJTAB_OP_SETBIND   = 4'd6,
    APU_OBJTAB_OP_RESET_CTX = 4'd7,
    APU_OBJTAB_OP_SETAUX    = 4'd8,
    // §7b: mask/value applied to aux[63:32] instead of aux[31:0]
    // (object payload {base[15:0], words[15:0]} parking)
    APU_OBJTAB_OP_SETAUXHI  = 4'd9,
    // §7b/5a-ii: entry lookup by slot only (id[15:0]); no generation
    // check, no kind check, no directory probe.  MISS when the slot is
    // not live.  Used by the executor to resolve a bound-memory slot
    // recorded by SETBIND without a generational handle.
    APU_OBJTAB_OP_READSLOT  = 4'd10
  } apu_objtab_op_e;

  typedef enum logic [3:0] {
    APU_OBJTAB_OK            = 4'd0,
    APU_OBJTAB_DUP           = 4'd1,
    APU_OBJTAB_FULL          = 4'd2,
    APU_OBJTAB_MISS          = 4'd3,
    APU_OBJTAB_KIND          = 4'd4,
    APU_OBJTAB_PINNED        = 4'd5,
    APU_OBJTAB_BUSY_CHILDREN = 4'd6,
    APU_OBJTAB_GEN           = 4'd7,
    APU_OBJTAB_PARENT_MISS   = 4'd8,
    // RESET_CTX stream record: one interim completion per tombstoned
    // entry (handle[15:0] = slot, entry = the entry as swept) so the
    // caller can reclaim resources the sweep itself cannot reach
    // (aperture extents, ObjPay extents, ShaderCore slot refs).  The
    // final completion reports OK with the pinned count as before.
    APU_OBJTAB_SWEEP         = 4'd9
  } apu_objtab_status_e;

  typedef struct packed {
    apu_objtab_op_e op;
    logic [63:0]    id;
    logic [5:0]     kind;
    logic [63:0]    parent_id;   // 0 = no parent
    logic [7:0]     ctx;
    logic [31:0]    mask;
    logic [31:0]    value;
    logic [63:0]    mem_id;      // 0 = unbind
    logic [63:0]    offset;
    logic [63:0]    size;
  } apu_objtab_req_t;

  typedef struct packed {
    logic        live;
    logic [5:0]  kind;
    logic [15:0] gen;
    logic [15:0] parent_slot;    // 16'hFFFF = none
    logic [15:0] refcnt;
    logic [7:0]  pins;
    logic [31:0] state;
    logic [15:0] bind_mem_slot;  // 16'hFFFF = unbound
    logic [63:0] bind_offset;
    logic [63:0] size;
    logic [63:0] aux;          // user state (cmdrec buf idx in [7:0])
    logic [7:0]  ctx;
  } apu_objtab_entry_t;

  localparam logic [15:0] APU_OBJTAB_SLOT_NONE = 16'hFFFF;

  // Client-object id namespace tag (see header): ORed into every id-
  // form ObjTab request carrying a Vulkan client object id so it
  // always takes the directory-probe path, never the {gen,slot}
  // handle fast path.
  localparam logic [63:0] APU_VN_ID_TAG = 64'h0000_0002_0000_0000;

  typedef struct packed {
    apu_objtab_status_e status;
    logic [31:0]        handle;   // {gen[15:0], slot[15:0]}; RESET_CTX: pinned count in [15:0]
    apu_objtab_entry_t  entry;
  } apu_objtab_cpl_t;

endpackage
