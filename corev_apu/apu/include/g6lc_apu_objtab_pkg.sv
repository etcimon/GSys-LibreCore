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
//   64'h0000_0001_0000_0000 | id   — virtio-gpu resource ids
//                                    (APU_VG_ID_TAG, g6lc_apu_vg_pkg)
//   64'h0000_0003_0000_0000 | id   — virtio-gpu context ids
//                                    (APU_VG_CTX_TAG, g6lc_apu_vg_pkg)
// The three spaces are disjoint for client/resource/context ids below
// 2^32 — needed because the guest kernel draws ctx ids and resource
// ids from separate dense allocators (a live blob rid N must not
// DUP-block CTX_CREATE for ctx N; CTS max_concurrent.instance).
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
    APU_OBJTAB_OP_READSLOT  = 4'd10,
    // §12.3 F5-d: kill every live entry with parent_slot == id[15:0]
    // (raw slot addressing, no directory probe), then zero the
    // parent's refcnt so the parent's own RETIRE cannot stall on
    // BUSY_CHILDREN.  No SWEEP stream — children of this call own
    // nothing outside their parent's arena.  The final completion is
    // OK with handle[15:0] = number retired; MISS when the slot index
    // is out of range.
    APU_OBJTAB_OP_RETIRE_KIDS = 4'd11,
    // §12.3 3d-d: overlap scan for MAP_BLOB eviction — iterate the
    // slots and report the FIRST live entry of kind == req.kind, other
    // than the excluded slot req.id[15:0], whose DEVBACKED extent
    // [aux[63:32], aux[63:32]+size) overlaps the byte window
    // [req.offset, req.size).  OK + {gen,slot} handle + entry on a
    // match (repeat the scan after each eviction to take the next),
    // MISS when no conflicting entry exists.  One completion, no
    // SWEEP stream.
    APU_OBJTAB_OP_SCAN_OVL   = 4'd12,
    // §12.3 3d-d: compare-and-set publish of aux[63:32] — writes
    // aux[63:32] := req.value and ORs req.mask into aux[31:0] only
    // while the entry's aux[63:32] still equals req.offset[31:0];
    // CONFLICT (with the live entry) otherwise.  The two agents that
    // can publish a DEVICE_MEMORY base — vnfront's bind-time DEVBACKED
    // backing (ring queue) and vgctl's MAP_BLOB (ctrl queue) — issue
    // on unordered queues, so each publish must be atomic against the
    // other: whichever lands second either skips (bind sees a placed
    // base) or restarts as a relocation (map sees DEVBACKED).
    APU_OBJTAB_OP_SETAUXHI_CAS = 4'd13
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
    APU_OBJTAB_SWEEP         = 4'd9,
    // §12.3 3d-d: SETAUXHI_CAS compare failed — another agent already
    // published a base; the returned entry carries it
    APU_OBJTAB_CONFLICT      = 4'd10
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
    logic [31:0] bind_mem;       // bound DEVICE_MEMORY {gen[31:16],
                                // slot[15:0]}; [15:0]==16'hFFFF = unbound
    logic [63:0] bind_offset;
    logic [63:0] size;
    logic [63:0] aux;          // user state (cmdrec buf idx in [7:0])
    logic [7:0]  ctx;
  } apu_objtab_entry_t;

  localparam logic [15:0] APU_OBJTAB_SLOT_NONE = 16'hFFFF;

  // §12.3 C: VkDeviceMemory aux[63:32] unbacked sentinel — a type-1
  // (host-visible) allocation is lazy at vkAllocateMemory: it holds
  // no aperture pages until bound or mapped.  Engine uses
  // (descriptor bound-write, Xfer operand, dispatch) must still
  // refuse the sentinel, never fabricate a base — §12.3 3d-d makes
  // that an invariant legal traffic cannot reach.
  localparam logic [31:0] APU_MEM_UNBACKED = 32'hFFFF_FFFF;

  // §12.3 3d-d: VkDeviceMemory aux[0] = DEVBACKED — the memory's
  // aperture extent was chosen by the DEVICE (vnfront ALLOC_HI at
  // bind time, top-down in the guest window) and is relocatable.
  // Three backing states for a DEVICE_MEMORY entry:
  //   aux[63:32] == APU_MEM_UNBACKED          — lazy, no extent
  //   DEVBACKED set                          — device-chosen extent,
  //                                            MAP_BLOB may relocate it
  //   DEVBACKED clear, base != UNBACKED      — kernel-chosen extent
  //                                            (ALLOC_AT at MAP_BLOB)
  localparam logic [63:0] APU_MEM_DEVBACKED = 64'h1;

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

  // ------------------------------------------------------------------
  // §5a G3b-i: object memory (objmem) backing layout and the
  // g6lc_apu_objtab/g6lc_apu_objpay <-> g6lc_apu_objmem interface.
  //
  // Carve (aperture-relative, above the vgpages-managed window):
  //   [APU_OBJMEM_OFF, +ObjEntries*64)           entry records (64 B)
  //   [dir_off,        +2*ObjEntries*8)          id directory buckets
  //   [stk_off,        +ObjEntries*2)            global free stack
  //   [pay_off,        +PayMemBytes)             ObjPay payload arena
  // pay_off is the first 64 KiB boundary after the stack.  All of it
  // sits under APU_VG_SHM_BYTES; vgtop/vgsys assert the fit.
  localparam logic [63:0] APU_OBJMEM_OFF = 64'h0480_0000; // 72 MiB
  // (above the 64 MiB guest window + 8 MiB private arena — §5a
  //  revision 2026-10-16, API-X4 guest-window growth)

  function automatic logic [63:0] apu_objmem_dir_off(
      input int unsigned entries);
    return APU_OBJMEM_OFF + 64'(entries) * 64'd64;
  endfunction
  function automatic logic [63:0] apu_objmem_stk_off(
      input int unsigned entries);
    return apu_objmem_dir_off(entries) + 64'(entries) * 64'd16;
  endfunction
  function automatic logic [63:0] apu_objmem_pay_off(
      input int unsigned entries);
    return (apu_objmem_stk_off(entries) + 64'(entries) * 64'd2 +
            64'hFFFF) & ~64'hFFFF;
  endfunction

  // Entry record (64 B).  Word offsets (32-bit words, little-endian
  // packing as stored):
  //   w0  {pad[31:24], ctx[23:16], pins[15:8], pad[7],
  //        kind[6:1], live[0]}
  //   w1  {parent_slot[31:16], gen[15:0]}
  //   w2  {pad[31:16], refcnt[15:0]}
  //   w3  state[31:0]
  //   w4  bind_mem[31:0]
  //   w5  bind_offset[31:0]        w6  bind_offset[63:32]
  //   w7  size[31:0]               w8  size[63:32]
  //   w9  aux[31:0]                w10 aux[63:32]
  //   w11 {ctx_prev[31:16],  ctx_next[15:0]}   per-context live list
  //   w12 {kind_prev[31:16], kind_next[15:0]}  DEVICE_MEMORY list only
  //   w13 id[31:0]                 w14 id[63:32]
  //   w15 epoch[31:0]              objmem generation epoch
  // `id` is stored in the entry so a directory probe hit is verified
  // against the full 64-bit id (the 42-bit bucket tag is a hint) and a
  // stale row — slot recycled under a different id — is detected by
  // id mismatch rather than by a generation remembered in the row.
  // `epoch` is stamped by objmem on every entry write; an entry whose
  // epoch differs from the current one is dead (reset semantics).
  typedef struct packed {
    logic [31:0] epoch;                       // w15
    logic [63:0] id;                          // w13..14
    logic [15:0] kind_prev, kind_next;        // w12
    logic [15:0] ctx_prev,  ctx_next;         // w11
    logic [63:0] aux;                         // w9..10
    logic [63:0] size;                        // w7..8
    logic [63:0] bind_offset;                 // w5..6
    logic [31:0] bind_mem;                    // w4
    logic [31:0] state;                       // w3
    logic [15:0] pad2, refcnt;                // w2
    logic [15:0] parent_slot, gen;            // w1
    logic [7:0]  pad0, ctx, pins;
    logic        pad7;                        // w0 bit 7 spare
    logic [5:0]  kind;
    logic        live;                        // w0
  } apu_objent_mem_t;
  localparam int unsigned APU_OBJENT_W_ID_LO  = 13;
  localparam int unsigned APU_OBJENT_W_ID_HI  = 14;
  localparam int unsigned APU_OBJENT_W_CTXLK  = 11;
  localparam int unsigned APU_OBJENT_W_KINDLK = 12;
  localparam int unsigned APU_OBJENT_W_AUX_LO = 9;
  localparam int unsigned APU_OBJENT_W_AUX_HI = 10;

  // Directory bucket (8 B): {valid[63], tomb[62], epoch[61:59],
  // pad[58], id_tag[57:16], entry[15:0]} with id_tag = id[41:0].  42 bits
  // cover every id the driver can mint (client/resource ids < 2^34
  // incl. the ns tags); the entry's stored id is the authoritative
  // check.  epoch[2:0] segregates rows across resets (see objmem).
  localparam int unsigned APU_OBJDIR_TAG_W = 42;

  // objmem object-table service port (ot side).  One request in
  // flight per client; exactly one rsp per request.
  typedef enum logic [3:0] {
    // directory id -> entry index (dir cache, then <=32-bucket
    // probe with lazy tombstoning of id-stale rows); rsp {hit,entry,
    // bucket}
    APU_OMT_FIND   = 4'd0,
    // ALLOC probe: rsp.status = DUP (entry)/CLAIM (bucket)/FULL;
    // lazily tombstones stale rows like FIND
    APU_OMT_CLAIM  = 4'd1,
    // write dir row {valid,id,entry} at req.bucket; updates the dir
    // cache
    APU_OMT_DWR    = 4'd2,
    // tombstone dir row at req.bucket; kills matching dir-cache way
    APU_OMT_DTOMB  = 4'd3,
    // entry cache access (line index = entry index)
    APU_OMT_ERD    = 4'd4,   // rsp.rec = 64 B record
    APU_OMT_EWR    = 4'd5,   // req.rec -> line, mark dirty
    // write back the entry's line iff dirty (RETIRE write-back point)
    APU_OMT_EWB    = 4'd6,
    // write back all dirty entry lines (RESET_CTX write-back point)
    APU_OMT_FLUSH  = 4'd7,
    // global free stack: POP -> rsp {hit,entry} (flop top, DRAM
    // refill, then the never-written bump region with gen=0);
    // PUSH(req.entry)
    APU_OMT_POP    = 4'd8,
    APU_OMT_PUSH   = 4'd9
  } apu_omt_op_e;

  typedef enum logic [2:0] {
    APU_OMT_OK    = 3'd0,   // generic success / FIND hit
    APU_OMT_MISS  = 3'd1,   // FIND/CLAIM: no live entry (CLAIM: claim
                            // granted — req.bucket carries it in rsp)
    APU_OMT_DUP   = 3'd2,   // CLAIM: live entry already owns the id
    APU_OMT_FULL  = 3'd3,   // CLAIM probe cap / POP empty
    APU_OMT_ERR   = 3'd4    // mp beat error
  } apu_omt_status_e;

  typedef struct packed {
    apu_omt_op_e     op;
    logic [63:0]     id;        // FIND/CLAIM/DWR
    logic [31:0]     bucket;    // DWR/DTOMB dir bucket index
    logic [15:0]     entry;     // DWR/ERD/EWR/EWB/PUSH entry index
    apu_objent_mem_t rec;       // EWR record
  } apu_omt_req_t;

  typedef struct packed {
    apu_omt_status_e status;
    logic [15:0]     entry;     // FIND/CLAIM hit / POP result
    logic [31:0]     bucket;    // FIND/CLAIM probe landing bucket
    logic            fresh;     // POP: entry from the bump region —
                                // never written, gen treated as 0
    apu_objent_mem_t rec;       // ERD record / FIND verified entry
  } apu_omt_rsp_t;

  // objmem payload service port (ObjPay side): one 64-B cache-line
  // op per request through the payload cache; ObjPay does its own
  // word extraction / merge.
  typedef struct packed {
    logic        dir;                 // 0 = dir0 entry region
    logic [25:0] line_addr;           // 64-B line index
    logic        we;
    logic [511:0] wdata;
  } apu_omp_req_t;

  typedef struct packed {
    logic        err;
    logic [511:0] rdata;
  } apu_omp_rsp_t;

endpackage
