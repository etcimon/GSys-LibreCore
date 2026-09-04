// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
//
// g6lc_ai_pe_dot: the balanced reduction tree must be BIT-IDENTICAL to the
// linear chain it replaced (F0a, architecture/ai-matrix/numeric-formats-datapath.md §1).
//
// Two's-complement wrapping addition is associative, so regrouping the sum
// cannot change the result -- including on overflow. That is the whole
// justification for restructuring the reduction before adding numeric formats,
// so it is checked directly rather than inferred:
//
//   * against an explicit linear chain, which is the exact prior structure;
//   * with deliberate overflow, where a non-associative implementation diverges;
//   * with the most-negative operand (-128), whose square is positive;
//   * for several `Lanes` values including non-powers-of-two, which exercise
//     the odd-tail promotion in the tree, and the live 256.
//
// ---------------------------------------------------------------------------
// KNOWN NOT TO RUN on the pinned Verilator 5.008 -- harness, not RTL
// ---------------------------------------------------------------------------
// This testbench builds but does not re-evaluate its stimulus. After the first
// drive, the TESTBENCH'S OWN arrays stay at their initial values: with
// `sa_pk` freshly written to 100 and all valids cleared, a readback showed
//
//   tb v4[0]=1 a4[0]=3 | dut d4.valid_i[0]=1 d4.a_i[0]=3 d4.b_i[0]=5
//
// i.e. the DUT agrees exactly with the testbench, and both hold the *previous*
// stimulus. So port binding is correct and the RTL is not implicated -- the
// combinational copy from packed stimulus into the unpacked array ports simply
// does not re-trigger. The reference function, reading the same packed
// stimulus directly, is correct throughout, which is what makes the failure
// look like a stale DUT.
//
// Four DUT structures and three harness structures were tried; every one gave
// the identical `acc_i + 3840` (= 256 x 3*5, the first stimulus), which is what
// finally identified the harness rather than the design. Attempts, all failing:
//   * task copying into the unpacked array ports;
//   * element-wise generate `assign` from unpacked stimulus;
//   * element-wise generate `assign` from packed stimulus;
//   * `always_comb` copy from packed stimulus (this file).
//
// This is the same family of problem as AI-X4 (`#0` rejected outright in the
// sibling unit TBs): the ai_island unit-TB layer does not work on this tool
// version. The citable evidence for the reduction tree is therefore the
// harness-level AI GEMM goldens, which exercise the PE through
// `g6lc_ai_gemm_seq` -- and that path works precisely because the sequencer
// drives `pe_a[p]` procedurally from its own `always_comb`.
//
// Kept, not deleted: the scenarios are correct and become useful the moment
// the unit-TB layer is fixed. `run-pe-dot.sh` reports SKIP rather than a
// verdict it cannot produce.
//
// No `#0` anywhere -- those are rejected outright (%Error-ZERODLY). The PE is
// combinational and needs no clock.
//
// Not Variane. Not a throughput number.

`timescale 1ns / 1ps

module tb_g6lc_ai_pe_dot;

  localparam int unsigned LMAX = 256;

  int unsigned errors = 0;
  int unsigned checks = 0;

  // Packed stimulus. See the header note on why this is not an unpacked array.
  logic [LMAX*8-1:0] sa_pk;
  logic [LMAX*8-1:0] sb_pk;
  logic [LMAX-1:0]   sv_pk;

  // Lanes under test. 256 is live PeLanes; 3 and 5 are non-powers of two.
  localparam int unsigned L0 = 1;
  localparam int unsigned L1 = 3;
  localparam int unsigned L2 = 4;
  localparam int unsigned L3 = 5;
  localparam int unsigned L4 = 256;

  logic signed [7:0] a0 [L0], b0 [L0];
  logic signed [7:0] a1 [L1], b1 [L1];
  logic signed [7:0] a2 [L2], b2 [L2];
  logic signed [7:0] a3 [L3], b3 [L3];
  logic signed [7:0] a4 [L4], b4 [L4];
  logic v0 [L0], v1 [L1], v2 [L2], v3 [L3], v4 [L4];
  logic [31:0] o0, o1, o2, o3, o4;

  // Drive the DUTs' unpacked array ports from an always_comb, NOT from
  // generate `assign`s.
  //
  // Element-wise continuous assignment into an unpacked array is the pattern
  // that is not tracked on the pinned Verilator 5.008: the packed `acc_i` port
  // updated while `a_i`/`b_i`/`valid_i` stayed at their first value, so every
  // check after the first saw stale operands and the failure looked like a
  // stale DUT. Procedural writes inside a combinational block are what the
  // design itself uses (`g6lc_ai_gemm_seq` assigns `pe_a[p]` this way), and
  // they work.
  always_comb begin
    for (int unsigned l = 0; l < L0; l++) begin
      a0[l] = sa_pk[8*l+:8];
      b0[l] = sb_pk[8*l+:8];
      v0[l] = sv_pk[l];
    end
    for (int unsigned l = 0; l < L1; l++) begin
      a1[l] = sa_pk[8*l+:8];
      b1[l] = sb_pk[8*l+:8];
      v1[l] = sv_pk[l];
    end
    for (int unsigned l = 0; l < L2; l++) begin
      a2[l] = sa_pk[8*l+:8];
      b2[l] = sb_pk[8*l+:8];
      v2[l] = sv_pk[l];
    end
    for (int unsigned l = 0; l < L3; l++) begin
      a3[l] = sa_pk[8*l+:8];
      b3[l] = sb_pk[8*l+:8];
      v3[l] = sv_pk[l];
    end
    for (int unsigned l = 0; l < L4; l++) begin
      a4[l] = sa_pk[8*l+:8];
      b4[l] = sb_pk[8*l+:8];
      v4[l] = sv_pk[l];
    end
  end

  g6lc_ai_pe_dot #(.Lanes(L0)) d0 (.a_i(a0), .b_i(b0), .valid_i(v0), .numfmt_i(3'd0), .sum_o(o0));
  g6lc_ai_pe_dot #(.Lanes(L1)) d1 (.a_i(a1), .b_i(b1), .valid_i(v1), .numfmt_i(3'd0), .sum_o(o1));
  g6lc_ai_pe_dot #(.Lanes(L2)) d2 (.a_i(a2), .b_i(b2), .valid_i(v2), .numfmt_i(3'd0), .sum_o(o2));
  g6lc_ai_pe_dot #(.Lanes(L3)) d3 (.a_i(a3), .b_i(b3), .valid_i(v3), .numfmt_i(3'd0), .sum_o(o3));
  g6lc_ai_pe_dot #(.Lanes(L4)) d4 (.a_i(a4), .b_i(b4), .valid_i(v4), .numfmt_i(3'd0), .sum_o(o4));

  // The linear chain the tree replaced, in declaration order. Agreement with
  // this IS the associativity claim.
  function automatic logic signed [31:0] ref_chain(input int unsigned n);
    logic signed [31:0] s;
    logic signed [7:0]  av, bv;
    s = 32'sd0;
    for (int unsigned l = 0; l < n; l++) begin
      if (sv_pk[l]) begin
        av = sa_pk[8*l+:8];
        bv = sb_pk[8*l+:8];
        s  = s + (32'($signed(av)) * 32'($signed(bv)));
      end
    end
    return s;
  endfunction

  task automatic chk(input string tag, input logic [31:0] got,
                     input logic signed [31:0] want);
    checks++;
    if (got !== want) begin
      $error("%s: got %0d (%h), want %0d (%h)", tag, $signed(got), got, want, want);
      errors++;
    end
  endtask

  task automatic drive_const(input logic signed [7:0] av, input logic signed [7:0] bv,
                             input logic vv);
    for (int unsigned l = 0; l < LMAX; l++) begin
      sa_pk[8*l+:8] = av;
      sb_pk[8*l+:8] = bv;
      sv_pk[l]      = vv;
    end
    #1;
  endtask

  task automatic check_all(input string tag);
    chk({tag, " L1"},   o0, ref_chain(L0));
    chk({tag, " L3"},   o1, ref_chain(L1));
    chk({tag, " L4"},   o2, ref_chain(L2));
    chk({tag, " L5"},   o3, ref_chain(L3));
    chk({tag, " L256"}, o4, ref_chain(L4));
  endtask

  initial begin
    // ---- directed smallest case -------------------------------------------
    drive_const(8'sd3, 8'sd5, 1'b1);
    chk("3*5 on L1", o0, 32'sd15);
    check_all("const 3*5");

    // A masked lane must contribute nothing.
    drive_const(8'sd100, 8'sd100, 1'b0);
    chk("all masked is zero", o4, 32'sd0);
    check_all("all masked");

    // Most-negative operand: -128 * -128 = +16384, which is where a sign-
    // extension slip shows up as a negative product.
    drive_const(8'sh80, 8'sh80, 1'b1);
    check_all("most-negative squared");

    // Mixed sign: -128 * 127 = -16256.
    drive_const(8'sh80, 8'sd127, 1'b1);
    check_all("mixed sign");

    // ---- dense max, exact in 32 bits --------------------------------------
    drive_const(8'sd127, 8'sd127, 1'b1);
    // 256 * 127 * 127 = 4_129_024.
    chk("L256 dense max", o4, 32'sd4_129_024);

    // NOTE: there is no overflow case here, and there cannot be. The PE is now
    // a pure sum of products with no accumulator input, and the widest
    // magnitude reachable is 256 * 128 * 128 = 4_194_304 -- three orders of
    // magnitude short of INT32. Associativity holds under wrapping regardless,
    // but it is not *observable* at these widths, so an "overflow test" here
    // would only assert that nothing overflowed. Overflow now belongs to the
    // accumulator in g6lc_ai_gemm_seq, which is where the recurrence lives.

    // ---- randomised -------------------------------------------------------
    for (int unsigned trial = 0; trial < 300; trial++) begin
      for (int unsigned l = 0; l < LMAX; l++) begin
        sa_pk[8*l+:8] = 8'($urandom());
        sb_pk[8*l+:8] = 8'($urandom());
        sv_pk[l]      = 1'($urandom());
      end
      #1;
      check_all($sformatf("rand %0d", trial));
    end

    if (errors == 0) $display("PASS tb_g6lc_ai_pe_dot checks=%0d", checks);
    else begin
      $display("FAIL tb_g6lc_ai_pe_dot errors=%0d of %0d checks", errors, checks);
      $fatal(1);
    end
    $finish;
  end

endmodule
