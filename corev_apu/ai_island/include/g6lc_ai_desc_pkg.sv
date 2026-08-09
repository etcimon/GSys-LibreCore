// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai T2 descriptor ABI types and error codes.
// Normative layout: architecture/ai-matrix/isa-encoding.md §7.

package g6lc_ai_desc_pkg;

  localparam int unsigned DescBytes  = 64;
  localparam int unsigned DescBits   = DescBytes * 8;
  localparam int unsigned ContractVersion = 1;

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

  // Packed 64-byte descriptor (little-endian field view).
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

  // flags[19:16] priority, flags[13:8] type fields (dtype/accmode/ew/sp24)
  function automatic logic [3:0] desc_prio(input desc_t d);
    return d.flags[19:16];
  endfunction

  function automatic logic desc_irq(input desc_t d);
    return d.flags[2];
  endfunction

  // Completion word: {reserved[15:0], status[15:0], ticket[31:0]}
  function automatic logic [63:0] make_completion(
      input logic [31:0] ticket, input logic [15:0] status
  );
    return {16'h0, status, ticket};
  endfunction

endpackage
