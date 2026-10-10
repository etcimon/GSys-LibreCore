// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Config-dependent core struct types, as macros.
//
// WHY THIS FILE EXISTS
// --------------------
// SystemVerilog packages cannot be parameterized, so every one of these structs
// depends on `CVA6Cfg` and therefore has to live as a `localparam type` inside
// `core/cva6.sv` and be threaded down through `parameter type` ports. That works
// for the RTL, but it means the types are *unreachable* from anywhere that is not
// instantiated under `cva6`.
//
// The consequence showed up as soon as the formal program moved past the fetch
// plane: a proof that instantiates `decoder`, `id_stage`, `issue_read_operands`
// or `commit_stage` has to HAND-COPY the struct layouts into its own props file.
// That is a silent-divergence hazard of the worst kind -- a proof whose
// `scoreboard_entry_t` has drifted from the RTL's still elaborates, still
// "passes", and is quietly checking a different machine. The fetch harnesses each
// carry their own copies today (`core/fetch_B/formal/g6lc_fetch_hold_props.sv`
// reconstructs four of them, with a comment admitting they are
// "layout-identical to the localparam types in core/cva6.sv" -- an invariant
// maintained by hand and by hope).
//
// A macro header is the seam the codebase already uses for exactly this problem:
// see `core/include/rvfi_types.svh` and `core/include/cvxif_types.svh`, both
// included by `core/cva6.sv` and both taking the cfg as a macro argument. This
// file extends that established pattern to the pipeline types so that RTL and
// proofs can share ONE definition.
//
// ADOPTION IS DELIBERATELY INCREMENTAL
// ------------------------------------
// New formal harnesses should `include` this file instead of hand-copying. The
// matching change in `core/cva6.sv` -- replacing its `localparam type` bodies
// with these macros -- is a separate, wide-blast-radius edit that must be shown
// to be netlist-identical before it lands (I27: reducing a knob to baseline must
// yield a bit-identical baseline netlist, and this is the same standard applied
// to a refactor). Until then, THIS FILE IS THE COPY THAT MUST TRACK cva6.sv, and
// any edit to those `localparam type` bodies must be mirrored here. That is a
// worse invariant than having one definition, but it is a strictly better one
// than having N hand-copies in N props files, and it is written down.

`ifndef G6LC_CORE_TYPES_SVH
`define G6LC_CORE_TYPES_SVH

// Branch-prediction scoreboard entry (cva6.sv `branchpredict_sbe_t`).
`define G6LC_BRANCHPREDICT_SBE_T(cfg) struct packed {                          \
  ariane_pkg::cf_t         cf;                                                 \
  logic [(cfg).VLEN-1:0]   predict_address;                                    \
  logic                    ckpt_v;                                             \
  logic [7:0]              ckpt_idx;                                           \
  logic                    is_call;                                            \
}

// Exception (cva6.sv `exception_t`).
`define G6LC_EXCEPTION_T(cfg) struct packed {                                  \
  logic [(cfg).XLEN-1:0]   cause;                                              \
  logic [(cfg).XLEN-1:0]   tval;                                               \
  logic [(cfg).GPLEN-1:0]  tval2;                                              \
  logic [31:0]             tinst;                                              \
  logic                    gva;                                                \
  logic                    valid;                                             \
}

// Interrupt-control snapshot from the CSR file (cva6.sv `irq_ctrl_t`).
`define G6LC_IRQ_CTRL_T(cfg) struct packed {                                   \
  logic [(cfg).XLEN-1:0]   mie;                                                \
  logic [(cfg).XLEN-1:0]   mip;                                                \
  logic [(cfg).XLEN-1:0]   mideleg;                                            \
  logic [(cfg).XLEN-1:0]   hideleg;                                            \
  logic                    sie;                                                \
  logic                    global_enable;                                      \
}

// SMT thread-tag width: 1 when NrHarts<=1 so the tag is a constant-0 and the
// netlist stays inert (matches cva6.sv HART_ID_BITS).
`define G6LC_HART_ID_BITS(cfg) (((cfg).NrHarts <= 1) ? 1 : $clog2((cfg).NrHarts))

// ID/EX/WB scoreboard entry (cva6.sv `scoreboard_entry_t`).
// NOTE: `exception_t` and `branchpredict_sbe_t` must already be in scope, since
// this struct embeds them by name -- same requirement cva6.sv has.
`define G6LC_SCOREBOARD_ENTRY_T(cfg) struct packed {                           \
  logic [(cfg).VLEN-1:0]            pc;                                        \
  logic [(cfg).TRANS_ID_BITS-1:0]   trans_id;                                  \
  ariane_pkg::fu_t                  fu;                                        \
  ariane_pkg::fu_op                 op;                                        \
  logic [ariane_pkg::REG_ADDR_SIZE-1:0] rs1;                                   \
  logic [ariane_pkg::REG_ADDR_SIZE-1:0] rs2;                                   \
  logic [ariane_pkg::REG_ADDR_SIZE-1:0] rd;                                    \
  logic [(cfg).XLEN-1:0]            result;                                    \
  logic                             valid;                                     \
  logic                             use_imm;                                   \
  logic                             use_zimm;                                  \
  logic                             use_pc;                                    \
  exception_t                       ex;                                        \
  branchpredict_sbe_t               bp;                                        \
  logic                             is_compressed;                             \
  logic                             is_macro_instr;                            \
  logic                             is_last_macro_instr;                       \
  logic                             is_double_rd_macro_instr;                  \
  logic                             vfp;                                       \
  logic                             is_zcmt;                                   \
  logic [`G6LC_HART_ID_BITS(cfg)-1:0] hart_id;                                 \
  logic [7:0]                       p_rs1;                                     \
  logic [7:0]                       p_rs2;                                     \
  logic [7:0]                       p_rd;                                      \
  /* FP physical tags. Separate from the integer ones because the split       */\
  /* register class indexes a different file: one shared tag would force the  */\
  /* consumer to re-derive the operand class to know which file to read.      */\
  /* p_frs3 has no integer counterpart -- only FP has a third source.         */\
  logic [7:0]                       p_frs1;                                    \
  logic [7:0]                       p_frs2;                                    \
  logic [7:0]                       p_frs3;                                    \
  logic [7:0]                       p_frd;                                     \
  logic                             ooo_renamed;                               \
}

// Interrupt cause constants (cva6.sv `interrupts_t`).
`define G6LC_INTERRUPTS_T(cfg) struct packed {                                 \
  logic [(cfg).XLEN-1:0] S_SW;                                                 \
  logic [(cfg).XLEN-1:0] VS_SW;                                                \
  logic [(cfg).XLEN-1:0] M_SW;                                                 \
  logic [(cfg).XLEN-1:0] S_TIMER;                                              \
  logic [(cfg).XLEN-1:0] VS_TIMER;                                             \
  logic [(cfg).XLEN-1:0] M_TIMER;                                              \
  logic [(cfg).XLEN-1:0] S_EXT;                                                \
  logic [(cfg).XLEN-1:0] VS_EXT;                                               \
  logic [(cfg).XLEN-1:0] M_EXT;                                                \
  logic [(cfg).XLEN-1:0] HS_EXT;                                               \
  logic [(cfg).XLEN-1:0] LCOF;                                                 \
}

`endif
