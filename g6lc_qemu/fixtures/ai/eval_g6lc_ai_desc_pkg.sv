// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT

package g6q_eval_desc_pkg;
  localparam int unsigned DescBytes = 64;
  localparam int unsigned DescVersion = 2;
  localparam int unsigned DESC_B_K_MAJOR = 1;
  localparam logic [15:0] OP_GEMM = 16'd1;
  localparam logic [15:0] ST_OK = 16'd0;
  localparam logic [15:0] ST_ERR = 16'd1;
  localparam logic [15:0] ST_BAD_VER = 16'd2;
  localparam logic [15:0] ST_BAD_OP = 16'd3;
  localparam logic [15:0] ST_BAD_FMT = 16'd8;
  typedef logic [511:0] desc_bits_t;
  typedef struct packed {
    logic [63:0] ptr_done, ptr_scale, ptr_c, ptr_b, ptr_a;
    logic [31:0] ld_ab, k, n, m, flags;
    logic [15:0] op, version;
  } desc_t;
  function automatic desc_t bits_to_desc(input desc_bits_t b);
    desc_t d;
    d.version = b[15:0];
    d.op = b[31:16];
    d.flags = b[63:32];
    d.m = b[95:64];
    d.n = b[127:96];
    d.k = b[159:128];
    d.ld_ab = b[191:160];
    d.ptr_a = b[255:192];
    d.ptr_b = b[319:256];
    d.ptr_c = b[383:320];
    d.ptr_scale = b[447:384];
    d.ptr_done = b[511:448];
    return d;
  endfunction
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
  function automatic logic [2:0] desc_numfmt(input desc_t d);
    return d.flags[22:20];
  endfunction
  function automatic logic [63:0] make_completion(input logic [31:0] ticket, input logic [15:0] status);
    return {16'h0, status, ticket};
  endfunction
endpackage
