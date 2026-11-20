// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Query-pool counter delta and copy-record packer.  The functions
// are the single layout used by this module and by g6lc_apu_qrypool.
// Neither is instantiated in the product: the format-matrix lane owns
// the raster, the executor, and the profile.  timestampValidBits
// stays 0, so a timestamp query is a defined zero.
//
// The free-running bus is
// {fs_invocations, occlusion_samples, ia_primitives, ia_vertices}.
// VS-invocations reuse ia_vertices.  Statistics counters pack mask
// bits {0, 1, 2, 7} in that order.  A copy record is the counters,
// then an availability field when requested.  A 64-bit field is the
// value followed by a zero high word.  An unavailable slot writes
// zeros, including a zero availability word.
package g6lc_apu_qry_pkg;
  function automatic logic f_mask_bad(input logic [7:0] qtype,
                                      input logic [31:0] mask);
    if (qtype == 8'd1) f_mask_bad = |(mask & ~32'h87);
    else               f_mask_bad = (mask != 32'h0);
  endfunction

  function automatic logic [31:0] f_rec_bytes(input logic [3:0] n,
                                              input logic wide,
                                              input logic with_av);
    f_rec_bytes = (32'(n) + (with_av ? 32'd1 : 32'd0)) << (wide ? 3 : 2);
  endfunction

  // Returns the counter count and writes up to four packed words.
  function automatic logic [3:0] f_delta(
      input logic [7:0] qtype,
      input logic [31:0] mask,
      input logic [127:0] now,
      input logic [127:0] base,
      output logic [127:0] delta);
    logic [31:0] d_vtx, d_prim, d_occ, d_fs;
    logic [3:0] n;
    d_vtx  = now[31:0]   - base[31:0];
    d_prim = now[63:32]  - base[63:32];
    d_occ  = now[95:64]  - base[95:64];
    d_fs   = now[127:96] - base[127:96];
    n = 4'd0;
    delta = '0;
    if (qtype == 8'd0) begin
      n = 4'd1;
      delta[31:0] = d_occ;
    end else if (qtype == 8'd1) begin
      if (mask[0]) begin
        delta[32*n +: 32] = d_vtx;
        n = n + 4'd1;
      end
      if (mask[1]) begin
        delta[32*n +: 32] = d_prim;
        n = n + 4'd1;
      end
      if (mask[2]) begin
        delta[32*n +: 32] = d_vtx;
        n = n + 4'd1;
      end
      if (mask[7]) begin
        delta[32*n +: 32] = d_fs;
        n = n + 4'd1;
      end
    end else if (qtype == 8'd2) begin
      n = 4'd1;
      delta[31:0] = 32'h0;
    end
    f_delta = n;
  endfunction

  // Returns the data-word count.  rec[31:0] is word 0.
  function automatic logic [4:0] f_rec(
      input logic [3:0] n,
      input logic [127:0] words,
      input logic avail,
      input logic wide,
      input logic with_av,
      output logic [319:0] rec);
    logic [4:0] nw;
    logic [31:0] fld;
    nw = 5'd0;
    rec = '0;
    fld = 32'h0;
    // n == 0 still emits the availability word when requested.
    for (int f = 0; f < 5; f++) begin
      fld = 32'h0;
      if (f < int'(n) || (with_av && f == int'(n)))
        fld = (f == int'(n)) ? {31'h0, avail} :
              (avail ? words[32*f +: 32] : 32'h0);
      if (f < int'(n) || (with_av && f == int'(n))) begin
        if (wide) begin
          rec[32*nw +: 32] = fld;
          nw = nw + 5'd1;
          rec[32*nw +: 32] = 32'h0;
          nw = nw + 5'd1;
        end else begin
          rec[32*nw +: 32] = fld;
          nw = nw + 5'd1;
        end
      end
    end
    f_rec = nw;
  endfunction
endpackage

module g6lc_apu_qrydelta (
  input  logic [7:0]        qtype_i,
  input  logic [31:0]       mask_i,
  input  logic [127:0]      now_i,
  input  logic [127:0]      base_i,
  input  logic              slot_avail_i,
  input  logic [31:0]       flags_i,
  // When set, the copy record is built from stored_i rather than
  // from the live delta.  The pool uses this for a published slot.
  input  logic              use_stored_i,
  input  logic [3:0]        stored_n_i,
  input  logic [3:0][31:0]  stored_i,
  output logic [3:0]        n_o,
  output logic [3:0][31:0]  delta_o,
  output logic [4:0]        nw_o,
  output logic [9:0][31:0]  rec_o
);
  import g6lc_apu_qry_pkg::*;
  logic [127:0] delta_p, src_p;
  logic [319:0] rec_p;
  logic [3:0] src_n;

  always_comb begin
    n_o = f_delta(qtype_i, mask_i, now_i, base_i, delta_p);
    for (int k = 0; k < 4; k++)
      delta_o[k] = delta_p[32*k +: 32];
    src_n = use_stored_i ? stored_n_i : n_o;
    src_p = '0;
    for (int k = 0; k < 4; k++)
      src_p[32*k +: 32] = use_stored_i ? stored_i[k] : delta_o[k];
    nw_o = f_rec(src_n, src_p, slot_avail_i, flags_i[0], flags_i[3], rec_p);
    for (int k = 0; k < 10; k++)
      rec_o[k] = rec_p[32*k +: 32];
  end
endmodule
