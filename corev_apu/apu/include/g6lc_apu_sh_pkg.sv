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
  localparam int APU_SH_PTR_OFF = 0;
  localparam int APU_SH_PTR_TAG = 1;

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
