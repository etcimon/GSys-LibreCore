// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai T2 descriptor ABI types and error codes.
// Normative layout: architecture/ai-matrix/isa-encoding.md §7.

package g6lc_ai_desc_pkg;

  localparam int unsigned DescBytes  = 64;
  localparam int unsigned DescBits   = DescBytes * 8;
  localparam int unsigned ContractVersion = 1;
  // Ingested name (F2). Keep equal to ContractVersion (engine checks 16'(ContractVersion)).
  localparam logic [15:0] DESC_VERSION = 16'd1;

  // flags subfield layout (isa-encoding.md §7) — F5/F10.
  localparam int unsigned FLAG_DTYPE_SHIFT   = 8;
  localparam int unsigned FLAG_DTYPE_WIDTH   = 2;
  localparam int unsigned FLAG_ACCMODE_SHIFT = 10;
  localparam int unsigned FLAG_ACCMODE_WIDTH = 2;
  localparam int unsigned FLAG_EW_SHIFT      = 12;
  localparam int unsigned FLAG_EW_WIDTH      = 2;
  localparam int unsigned FLAG_SP24_SHIFT    = 14;
  localparam int unsigned FLAG_IRQ_SHIFT     = 2;
  localparam int unsigned FLAG_PRIO_SHIFT    = 16;
  localparam int unsigned FLAG_PRIO_WIDTH    = 4;
  // Numeric format selector, carved from flags[22:20] (previously reserved).
  //
  // Values are `config_pkg::AI_FMT_*`, and AI_FMT_INT == 0 -- so a descriptor
  // built before this field existed, with the whole word zero, still means
  // "integer, width from ew, signedness from dtype". That is what makes this an
  // extension rather than a version bump (isa-encoding.md §9): no shipped image
  // changes meaning.
  //
  // The engine must check the request against the granted mask
  // (CAP_OFF_DTYPE_MASK) and REFUSE an ungranted format. Demoting silently to
  // INT8 would return numerically plausible garbage, which for a tensor engine
  // is worse than an error status.
  localparam int unsigned FLAG_NUMFMT_SHIFT  = 20;
  localparam int unsigned FLAG_NUMFMT_WIDTH  = 3;

  // Descriptor op field (offset 0x02)
  localparam logic [15:0] OP_GEMM    = 16'd1;
  localparam logic [15:0] OP_CONV2D  = 16'd2;
  localparam logic [15:0] OP_LAYOUT  = 16'd3;
  localparam logic [15:0] OP_PREFETCH = 16'd4;

  // Completion / poll status
  localparam logic [15:0] ST_OK      = 16'd0;
  localparam logic [15:0] ST_ERR     = 16'd1;  // generic
  localparam logic [15:0] ST_BAD_VER = 16'd2;
  localparam logic [15:0] ST_BAD_OP  = 16'd3;
  localparam logic [15:0] ST_BAD_PTR = 16'd4;  // AI-3 address check fail
  localparam logic [15:0] ST_BAD_QID = 16'd5;
  localparam logic [15:0] ST_DISABLED = 16'd6;
  localparam logic [15:0] ST_WATCHDOG = 16'd7;
  // Requested numeric format (flags.numfmt) is not in the granted mask.
  // Distinct from ST_BAD_OP so software can tell "this engine cannot do BF16"
  // from "this opcode does not exist" and fall back deliberately rather than
  // guessing.
  localparam logic [15:0] ST_BAD_FMT = 16'd8;

  // Packed 64-byte descriptor (little-endian field view).
  // +0xNN comments are **byte offsets** into the latch window (F4).
  // Software builds the memory image; the engine never reads aicfg.
  typedef struct packed {
    logic [63:0] ptr_done;     // +0x38
    logic [63:0] ptr_scale;    // +0x30
    logic [63:0] ptr_c;        // +0x28
    logic [63:0] ptr_b;        // +0x20
    logic [63:0] ptr_a;        // +0x18
    logic [31:0] ld_ab;        // +0x14  lda | (ldb << 16)
    logic [31:0] k;            // +0x10
    logic [31:0] n;            // +0x0C
    logic [31:0] m;            // +0x08
    logic [31:0] flags;        // +0x04
    logic [15:0] op;           // +0x02
    logic [15:0] version;      // +0x00
  } desc_t;

  // Flat wire form for ports
  typedef logic [DescBits-1:0] desc_bits_t;

  function automatic desc_t bits_to_desc(input desc_bits_t b);
    desc_t d;
    d.version   = b[15:0];
    d.op        = b[31:16];
    d.flags     = b[63:32];
    d.m         = b[95:64];
    d.n         = b[127:96];
    d.k         = b[159:128];
    d.ld_ab     = b[191:160];
    d.ptr_a     = b[255:192];
    d.ptr_b     = b[319:256];
    d.ptr_c     = b[383:320];
    d.ptr_scale = b[447:384];
    d.ptr_done  = b[511:448];
    return d;
  endfunction

  function automatic desc_bits_t desc_to_bits(input desc_t d);
    desc_bits_t b;
    b = '0;
    b[15:0]    = d.version;
    b[31:16]   = d.op;
    b[63:32]   = d.flags;
    b[95:64]   = d.m;
    b[127:96]  = d.n;
    b[159:128] = d.k;
    b[191:160] = d.ld_ab;
    b[255:192] = d.ptr_a;
    b[319:256] = d.ptr_b;
    b[383:320] = d.ptr_c;
    b[447:384] = d.ptr_scale;
    b[511:448] = d.ptr_done;
    return b;
  endfunction

  function automatic logic [1:0] desc_dtype(input desc_t d);
    return d.flags[FLAG_DTYPE_SHIFT +: FLAG_DTYPE_WIDTH];
  endfunction

  function automatic logic [1:0] desc_accmode(input desc_t d);
    return d.flags[FLAG_ACCMODE_SHIFT +: FLAG_ACCMODE_WIDTH];
  endfunction

  function automatic logic [1:0] desc_ew(input desc_t d);
    return d.flags[FLAG_EW_SHIFT +: FLAG_EW_WIDTH];
  endfunction

  function automatic logic desc_sp24(input desc_t d);
    return d.flags[FLAG_SP24_SHIFT];
  endfunction

  function automatic logic [2:0] desc_numfmt(input desc_t d);
    return d.flags[FLAG_NUMFMT_SHIFT +: FLAG_NUMFMT_WIDTH];
  endfunction

  // Is this descriptor's requested numeric format granted by `mask`
  // (the same bitmap the island publishes at CAP_OFF_DTYPE_MASK)?
  //
  // The grant bit index equals the request value by construction
  // (config_pkg::AI_FMT_*), so this is a shift-and-test, not a lookup table
  // that could drift out of step with the core's copy.
  //
  // A descriptor whose format is not granted must complete with
  // ST_BAD_FMT. It must NOT be demoted to INT8: the engine would return
  // numerically plausible results for the wrong arithmetic, and nothing
  // downstream could detect it.
  function automatic logic desc_numfmt_granted(input desc_t d, input logic [15:0] mask);
    return mask[desc_numfmt(d)];
  endfunction

  function automatic logic [3:0] desc_prio(input desc_t d);
    return d.flags[FLAG_PRIO_SHIFT +: FLAG_PRIO_WIDTH];
  endfunction

  function automatic logic desc_irq(input desc_t d);
    return d.flags[FLAG_IRQ_SHIFT];
  endfunction

  // Completion word: {reserved[15:0], status[15:0], ticket[31:0]}
  function automatic logic [63:0] make_completion(
      input logic [31:0] ticket, input logic [15:0] status
  );
    return {16'h0, status, ticket};
  endfunction

endpackage
