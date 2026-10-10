// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
// ShaderCore types (hand-written; §7a of
// architecture/uncore/apu-vulkan-engine.md).  The bit layouts below
// are the contract between the commit scanner and
// corev_apu/apu/tools/shader/spirv_scan.py — both must agree.
package g6lc_apu_sh_pkg;

  // ---- commit fault codes (APU_SH_FAULT_*) --------------------------
  localparam logic [7:0] APU_SH_FAULT_NONE      = 8'd0;
  localparam logic [7:0] APU_SH_FAULT_MAGIC     = 8'd1;
  localparam logic [7:0] APU_SH_FAULT_VERSION   = 8'd2;
  localparam logic [7:0] APU_SH_FAULT_CAP       = 8'd3;
  localparam logic [7:0] APU_SH_FAULT_MEMMODEL  = 8'd4;
  localparam logic [7:0] APU_SH_FAULT_ENTRY     = 8'd5;
  localparam logic [7:0] APU_SH_FAULT_EXECMODE  = 8'd6;
  localparam logic [7:0] APU_SH_FAULT_LOCALSIZE = 8'd7;
  localparam logic [7:0] APU_SH_FAULT_OPCODE    = 8'd8;
  localparam logic [7:0] APU_SH_FAULT_TYPE      = 8'd9;
  localparam logic [7:0] APU_SH_FAULT_DECOR     = 8'd10;
  localparam logic [7:0] APU_SH_FAULT_CONST     = 8'd11;
  localparam logic [7:0] APU_SH_FAULT_VAR       = 8'd12;
  localparam logic [7:0] APU_SH_FAULT_STORAGE   = 8'd13;
  localparam logic [7:0] APU_SH_FAULT_BOUND     = 8'd14;
  localparam logic [7:0] APU_SH_FAULT_REGS      = 8'd15;
  localparam logic [7:0] APU_SH_FAULT_TWO_ENTRY = 8'd16;
  localparam logic [7:0] APU_SH_FAULT_WORDS     = 8'd17;
  localparam logic [7:0] APU_SH_FAULT_FWDREF    = 8'd18;
  localparam logic [7:0] APU_SH_FAULT_SPEC      = 8'd19;
  localparam logic [7:0] APU_SH_FAULT_BRANCH    = 8'd20;

  // ---- work/dispatch completion codes ------------------------------
  localparam logic [7:0] APU_SH_DONE_OK          = 8'd0;
  localparam logic [7:0] APU_SH_DONE_FAULT       = 8'd1;
  localparam logic [7:0] APU_SH_DONE_UNSUPPORTED = 8'd2;
  localparam logic [7:0] APU_SH_DONE_BUDGET      = 8'd3;

  // ---- type kinds (type table w0[3:0]) ------------------------------
  localparam logic [3:0] APU_SH_TK_NONE   = 4'd0;
  localparam logic [3:0] APU_SH_TK_VOID   = 4'd1;
  localparam logic [3:0] APU_SH_TK_BOOL   = 4'd2;
  localparam logic [3:0] APU_SH_TK_INT    = 4'd3;
  localparam logic [3:0] APU_SH_TK_FLOAT  = 4'd4;
  localparam logic [3:0] APU_SH_TK_VEC    = 4'd5;
  localparam logic [3:0] APU_SH_TK_MAT    = 4'd6;
  localparam logic [3:0] APU_SH_TK_ARRAY  = 4'd7;
  localparam logic [3:0] APU_SH_TK_RARRAY = 4'd8;
  localparam logic [3:0] APU_SH_TK_STRUCT = 4'd9;
  localparam logic [3:0] APU_SH_TK_PTR    = 4'd10;
  localparam logic [3:0] APU_SH_TK_FUNC   = 4'd11;
  // §12.3 C/5b: image-family types — IMG cols[1:0] = sampled (1
  // sampled / 2 storage), comps[0] = arrayed, sign = depth
  localparam logic [3:0] APU_SH_TK_IMG    = 4'd12;
  localparam logic [3:0] APU_SH_TK_SAMP   = 4'd13;
  localparam logic [3:0] APU_SH_TK_SIMG   = 4'd14;

  // ---- storage classes ----------------------------------------------
  localparam logic [3:0] APU_SH_SC_UNIFORMCONST = 4'd0;
  localparam logic [3:0] APU_SH_SC_INPUT        = 4'd1;
  localparam logic [3:0] APU_SH_SC_UNIFORM      = 4'd2;
  localparam logic [3:0] APU_SH_SC_OUTPUT       = 4'd3;
  localparam logic [3:0] APU_SH_SC_WORKGROUP    = 4'd4;
  localparam logic [3:0] APU_SH_SC_PRIVATE      = 4'd6;
  localparam logic [3:0] APU_SH_SC_FUNCTION     = 4'd7;
  localparam logic [3:0] APU_SH_SC_PUSHCONST    = 4'd9;
  localparam logic [3:0] APU_SH_SC_SBUF         = 4'd12;

  // ---- builtins (decor table builtin field) --------------------------
  localparam logic [6:0] APU_SH_BI_NUMWG   = 7'd24;
  localparam logic [6:0] APU_SH_BI_WGSIZE  = 7'd25;
  localparam logic [6:0] APU_SH_BI_WGID    = 7'd26;
  localparam logic [6:0] APU_SH_BI_LID     = 7'd27;
  localparam logic [6:0] APU_SH_BI_GID     = 7'd28;
  localparam logic [6:0] APU_SH_BI_LINDEX  = 7'd29;
  localparam logic [7:0] APU_SH_BI_NONE    = 8'hFF;

  // ---- table words per entry (mirrors spirv_scan.py) -----------------
  localparam int APU_SH_TYPE_WORDS   = 3;
  localparam int APU_SH_CONST_WORDS  = 16;
  localparam int APU_SH_MEMBER_WORDS = 2;
  localparam int APU_SH_DECOR_WORDS  = 2;
  localparam int APU_SH_VAR_WORDS    = 2;
  localparam int APU_SH_INIT_WORDS   = 2;

  // ---- regmap word: {tag[1:0], idx[15:0], type_id[9:0], pad} ---------
  // tag: 0 = RF register, 1 = constant table entry
  // idx: RF register index or constant index * CONST_WORDS is NOT
  // used — constants are addressed by id directly in the const table.
  localparam logic [1:0] APU_SH_RT_REG   = 2'd0;
  localparam logic [1:0] APU_SH_RT_CONST = 2'd1;

  // ---- pointer register format (RF vec4 for pointer ids) -------------
  // comp0 = byte offset within the storage space
  // comp1 = {storage[3:0], builtin[7:0], set[7:0], binding[7:0],
  //          flags[4:0]}  (builtin 0xFF = none)
  // comp2 = descriptor-array element index (F5): written by
  //         OpAccessChain's first index when the base is a Uniform /
  //         StorageBuffer array of descriptor records; carried to the
  //         LSU, which uses it to select the memory-resident record.
  localparam int APU_SH_PTR_OFF = 0;
  localparam int APU_SH_PTR_TAG = 1;
  localparam int APU_SH_PTR_DIDX = 2;

  // ---- §12.3 F5+C/5b: memory-resident descriptors ---------------------
  // One descriptor record = APU_DESC_BYTES (32) aperture bytes at
  //   set_base[s] + boff.off32*32 + array_index*32:
  //   +0   base[31:0]    aperture byte offset of the resource (images:
  //                      view's first subresource = mem base + bind
  //                      offset + off(baseLayer, baseMip))
  //   +4   size[31:0]    byte extent (images: bytes the view may touch)
  //   +8   kind[7:0]     VkDescriptorType (0 sampler, 1 combined,
  //                      2 sampled image, 3 storage image, 6/7 buffer,
  //                      8/9 dynamic)
  //   +9   flags[7:0]    bit0 = valid
  //   +10  w[15:0]       view mip-0 width  (image records)
  //   +12  h[15:0]       view mip-0 height
  //   +14  fmt[7:0]      APU_IMG_FMT_* device format id
  //   +15  {rsvd2, dim[1:0], mips[3:0]}  dim 0=2D 1=2D-array
  //   +16  layers[15:0]
  //   +18  swizzle[11:0] 4x3b {a,b,g,r} VkComponentSwizzle; 0 = identity
  //   +20  sampler w0: {rsvd11, {cmpEn,cmpOp3}, border3,
  //                    addrW/V/U 3x3b, mipmap1, minF2, magF2}
  //   +24  sampler w1: {rsvd7, bias9{s4.4}, maxLod8 u4.4, minLod8 u4.4}
  //   +28..+31 reserved zero
  // A sampler record (kind 0) fills only +20..+27; a sampled/storage
  // image record (kind 2/3) fills +0..+19; combined (1) fills both.
  // OpSampledImage merges a kind-2 and a kind-0 record at the LSU.
  // An all-zero (null/invalid) record bounds-checks as a zero-size
  // buffer: loads read 0, stores drop, robust_q++.
  // Scaling levers toward UE SM5 / CS2-class bindless:
  //   APU_DESC_SETS  bound sets per dispatch — must equal the profile's
  //                  maxBoundDescriptorSets
  //   APU_DESC_BND   binding rows per set in the dispatch sideband —
  //                  profile per-stage/per-set descriptor limits must
  //                  not exceed this
  //   APU_DESC_DYN   dynamic-offset slots per set — profile
  //                  maxDescriptorSet*Dynamic must not exceed this
  //   APU_DESC_CACHE LSU record-cache entries (dispatch-scoped flops;
  //                  the only per-access flop cost — grow for more
  //                  distinct {set,binding,idx} keys per dispatch)
  //   record arena   the device-private aperture tail
  //                  (g6lc_apu_pkg::APU_SHM_BYTES - APU_SHM_GUEST_BYTES);
  //                  pool arenas are carved from it by vgpages
  //                  ALLOC_PRIV, so descriptor capacity scales with the
  //                  aperture, not with flops
  localparam int unsigned APU_DESC_BYTES = 32;
  localparam int unsigned APU_DESC_WORDS = 8;     // 32-byte records
  localparam int unsigned APU_DESC_SETS  = 4;     // maxBoundDescriptorSets
  localparam int unsigned APU_DESC_BND   = 16;    // binding rows per set
  localparam int unsigned APU_DESC_DYN   = 16;    // dynamic elems per set
  localparam int unsigned APU_DESC_CACHE = 8;     // LSU record cache entries
  localparam int unsigned APU_DESC_POISON = 31;   // set aux poison bit

  // binding row — one per descriptor-set-layout binding, stored in the
  // layout's ObjPay payload as two words (vnfront writes, cmdexec and
  // vn_golden mirror the packing; the {w0,w1} low 49 bits cast to the
  // struct below):
  //   w0 = {binding[31:24], type[23:16], count[15:0]}
  //   w1 = {off32[31:12], dyn[11], pad[10:4], dynbase[3:0]}
  typedef struct packed {
    logic [7:0]  binding;   // descriptor binding number
    logic [15:0] count;     // array element count (0 = row absent)
    logic [19:0] off32;     // record offset in the set, 32-byte units
    logic        dyn;       // *_DYNAMIC descriptor type
    logic [3:0]  dynbase;   // per-set dynamic ordinal of element 0
  } apu_sh_bindrow_t;

  // dispatch sideband replacing the 16x113 flop bind table: the LSU
  // resolves (set,binding,idx) through boff (a 16-entry CAM per bound
  // set), then fetches the record at set_base[set] + off32*32 + idx*32
  // through the shared memory port, adding dyn_off[set][dynbase+idx]
  // for *_DYNAMIC kinds.
  typedef struct packed {
    apu_sh_bindrow_t [APU_DESC_SETS-1:0][APU_DESC_BND-1:0] boff;
    logic            [APU_DESC_SETS-1:0][31:0]             set_base;
    logic            [APU_DESC_SETS-1:0][APU_DESC_DYN-1:0][31:0] dyn_off;
  } apu_sh_desc_t;

  // ---- commit status record (out of shmod) ---------------------------
  typedef struct packed {
    logic [7:0]  code;      // APU_SH_FAULT_*
    logic [15:0] opcode;    // offending opcode / ExtInst number
    logic [15:0] word;      // module word index of the fault
  } apu_sh_fault_t;

  typedef struct packed {
    logic [15:0] entry_off;   // word offset of OpFunction
    logic [7:0]  lx, ly, lz;  // OpExecutionMode LocalSize
    logic [15:0] scratch;     // Function/Private bytes per invocation
    logic [15:0] slab;        // Workgroup slab bytes
  } apu_sh_entry_t;

  // ---- commit request/completion ------------------------------------
  typedef struct packed {
    logic [2:0]  slot;
    logic [15:0] nwords;
  } apu_sh_commit_t;

  typedef struct packed {
    logic          ok;
    apu_sh_fault_t fault;
    apu_sh_entry_t entry;
    logic [15:0] n_regs;
    logic [15:0] n_vars;
  } apu_sh_cpl_t;

  // ---- dispatch record (cmdexec work → shwave) -----------------------
  // For vkCmdDispatch the cmdrec imm words are {gx,gy,gz}.  The
  // pipeline handle resolves to a module slot out-of-band (4a: slot
  // supplied directly); descriptor state supplies a 16-entry binding
  // table {set[3:0],binding[4:0]} -> {base,size} and the push block.
  typedef struct packed {
    logic [63:0] base;
    logic [31:0] size;
    logic        valid;
  } apu_sh_bind_t;

  typedef struct packed {
    logic [2:0]      slot;      // committed module slot
    logic [15:0]     gx, gy, gz;
    logic [31:0]     work_id;
  } apu_sh_dispatch_t;

  typedef struct packed {
    logic [7:0]  code;        // APU_SH_DONE_*
    logic [15:0] wave;
    logic [15:0] pc;
    logic [31:0] robust;      // robustBufferAccess fault count
    logic [31:0] work_id;
  } apu_sh_done_t;

  // ---- slot manager (§7b/5a-ii) --------------------------------------
  // Module/pipeline slot ownership.  ALLOC returns a free slot with
  // users=1 (none free -> ok=0); REF increments users (ok=0 when the
  // slot is dead); UNREF decrements (ok=0 on underflow) and retires
  // the slot internally when users reaches 0.
  typedef enum logic [1:0] {
    APU_SH_SM_ALLOC = 2'd0,
    APU_SH_SM_REF   = 2'd1,
    APU_SH_SM_UNREF = 2'd2
  } apu_sh_sm_op_e;

  typedef struct packed {
    apu_sh_sm_op_e op;
    logic [2:0]    slot;    // REF/UNREF target; unused for ALLOC
  } apu_sh_sm_req_t;

  typedef struct packed {
    logic          ok;
    logic [2:0]    slot;    // ALLOC result
  } apu_sh_sm_cpl_t;

  // ---- shmod read port table select ----------------------------------
  typedef enum logic [3:0] {
    APU_SH_TBL_PROG   = 4'd0,   // program words
    APU_SH_TBL_TYPE   = 4'd1,   // 3 words/id
    APU_SH_TBL_CONST  = 4'd2,   // 16 words/id
    APU_SH_TBL_MEMBER = 4'd3,   // 2 words/entry
    APU_SH_TBL_DECOR  = 4'd4,   // 2 words/id
    APU_SH_TBL_VAR    = 4'd5,   // 2 words/id
    APU_SH_TBL_REGMAP = 4'd6,   // 1 word/id
    APU_SH_TBL_INIT   = 4'd7,   // 2 words/entry
    APU_SH_TBL_ENTRY  = 4'd8,   // 4 words (entry record)
    APU_SH_TBL_BLOCK  = 4'd9    // 1 word/label id -> pc + valid
  } apu_sh_tbl_e;

endpackage
