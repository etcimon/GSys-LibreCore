// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

package g6lc_ai_desc_pkg;
  localparam int unsigned DescBytes = 64;
  localparam logic [15:0] OP_GEMM   = 16'd1;
  localparam logic [15:0] ST_OK     = 16'd0;

  typedef logic [511:0] desc_bits_t;

  typedef struct packed {
    logic [63:0] ptr_done;     // +0x38
    logic [63:0] ptr_scale;    // +0x30
    logic [63:0] ptr_c;        // +0x28
    logic [63:0] ptr_b;        // +0x20
    logic [63:0] ptr_a;        // +0x18
    logic [31:0] ld_ab;        // +0x14
    logic [31:0] k;            // +0x10
    logic [31:0] n;            // +0x0C
    logic [31:0] m;            // +0x08
    logic [31:0] flags;        // +0x04
    logic [15:0] op;           // +0x02
    logic [15:0] version;      // +0x00
  } desc_t;

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

  // A deliberately stale combined comment, kept so the reader's
  // accessor-beats-comment rule is exercised: flags[13:8] type fields (dtype/accmode/ew)
  //
  // The per-field accessors below are the shape g6lc_qemu asks the design for in
  // architecture/RTL_FEEDBACK.md F10, and match isa-encoding.md §7. This fixture publishes
  // them so the ingest path for sub-byte and sparse requests is testable; the live package
  // does not, which is what the F10 row records.
  function automatic logic [1:0] desc_dtype(input desc_t d);
    return d.flags[9:8];
  endfunction

  function automatic logic [1:0] desc_accmode(input desc_t d);
    return d.flags[11:10];
  endfunction

  function automatic logic [1:0] desc_ew(input desc_t d);
    return d.flags[13:12];
  endfunction

  function automatic logic desc_sp24(input desc_t d);
    return d.flags[14];
  endfunction

  function automatic logic [3:0] desc_prio(input desc_t d);
    return d.flags[19:16];
  endfunction

  function automatic logic desc_irq(input desc_t d);
    return d.flags[2];
  endfunction

  function automatic logic [63:0] make_completion(
      input logic [31:0] ticket, input logic [15:0] status
  );
    return {16'h0, status, ticket};
  endfunction
endpackage
