// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
//
// hyp8 r127: equivalence of the aes.sv forms rewritten in r127 (transcribed):
//   - the four aes32 rotates: variable shift pair vs 4-way byte-rotate select,
//     exhaustive over the registered S-box byte and the byte index;
//   - the aes64ks1i subword input: whole-word select vs per-byte lanes,
//     every round value x directed and random words.
// The forms sit behind module ports and the stimulus is in plain variables.
// -DG6LC_MUT_AES_EQ swaps one rotate arm (negative control, must FAIL).
module aes_forms import aes_pkg::*; (
    input  logic [7:0]  sb_i,
    input  logic [1:0]  bs_i,
    input  logic [31:0] hi_i,
    input  logic [3:0]  rnum_i,
    output logic [31:0] o_sf, o_si, o_mf, o_mi, o_sub,
    output logic [31:0] n_sf, n_si, n_mf, n_mi, n_sub
);
  logic [5:0] orig_q;
  assign orig_q = {bs_i, 4'b0};
  // old forms
  assign o_sf = ({24'b0, sb_i} << {orig_q[5:4], 3'b000}) | ({24'b0, sb_i} >> (32 - {orig_q[5:4], 3'b000}));
  assign o_si = ({24'b0, sb_i} << {orig_q[5:4], 3'b000}) | ({24'b0, sb_i} >> (32 - {orig_q[5:4], 3'b000}));
  assign o_mf = (aes_mixcolumn_fwd({24'h000000, sb_i}) << {orig_q[5:4], 3'b000}) |
                (aes_mixcolumn_fwd({24'h000000, sb_i}) >> (32 - {orig_q[5:4], 3'b000}));
  assign o_mi = (aes_mixcolumn_inv({24'h000000, sb_i}) << {orig_q[5:4], 3'b000}) |
                (aes_mixcolumn_inv({24'h000000, sb_i}) >> (32 - {orig_q[5:4], 3'b000}));
  assign o_sub = (rnum_i == 4'hA) ? hi_i : ((hi_i >> 8) | (hi_i << 24));
  // new forms
  function automatic logic [31:0] aes_rol8x(input logic [31:0] x, input logic [1:0] bs);
    unique case (bs)
      2'd0:    return x;
`ifdef G6LC_MUT_AES_EQ
      2'd1:    return {x[15:0], x[31:16]};
`else
      2'd1:    return {x[23:0], x[31:24]};
`endif
      2'd2:    return {x[15:0], x[31:16]};
      default: return {x[7:0],  x[31:8]};
    endcase
  endfunction
  logic [31:0] mix_fwd_w, mix_inv_w;
  assign mix_fwd_w = aes_mixcolumn_fwd({24'h000000, sb_i});
  assign mix_inv_w = aes_mixcolumn_inv({24'h000000, sb_i});
  assign n_sf = aes_rol8x({24'b0, sb_i}, orig_q[5:4]);
  assign n_si = aes_rol8x({24'b0, sb_i}, orig_q[5:4]);
  assign n_mf = aes_rol8x(mix_fwd_w, orig_q[5:4]);
  assign n_mi = aes_rol8x(mix_inv_w, orig_q[5:4]);
  for (genvar bl = 0; bl < 4; bl++) begin : gen_subw_lane
    logic no_rot;
    assign no_rot = (rnum_i == 4'hA);
    assign n_sub[8*bl +: 8] = no_rot ? hi_i[8*bl +: 8] : hi_i[8*((bl + 1) % 4) +: 8];
  end
endmodule

module tb_g6lc_hyp8_aes_eq;
  logic [7:0]  sb; logic [1:0] bs; logic [31:0] hi; logic [3:0] rnum;
  logic [31:0] o_sf, o_si, o_mf, o_mi, o_sub, n_sf, n_si, n_mf, n_mi, n_sub;
  aes_forms u (.sb_i(sb), .bs_i(bs), .hi_i(hi), .rnum_i(rnum), .*);
  int unsigned checked = 0, bad = 0;
  task automatic cmp();
    #1; checked++;
    if ({o_sf, o_si, o_mf, o_mi, o_sub} !== {n_sf, n_si, n_mf, n_mi, n_sub}) begin
      bad++;
      if (bad < 5) $display("FAIL sb=%h bs=%0d hi=%h rnum=%h old=%h new=%h", sb, bs, hi, rnum,
                            {o_sf, o_mf, o_mi, o_sub}, {n_sf, n_mf, n_mi, n_sub});
    end
  endtask
  initial begin
    hi = 32'h8877_6655; rnum = 4'h0;
    for (int unsigned s = 0; s < 256; s++)
      for (int unsigned b = 0; b < 4; b++) begin sb = 8'(s); bs = 2'(b); cmp(); end
    sb = 8'h5a; bs = 2'd1;
    for (int unsigned r = 0; r < 16; r++)
      for (int unsigned i = 0; i < 2000; i++) begin
        rnum = 4'(r); hi = (i == 0) ? 32'h4433_2211 : $urandom(); cmp();
      end
    if (bad == 0 && checked != 0) $display("HYP8_AES_EQ_PASS checked=%0d", checked);
    else $display("HYP8_AES_EQ_FAIL checked=%0d bad=%0d", checked, bad);
    $finish;
  end
endmodule
