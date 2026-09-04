// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Xg6lcai I1 PE slice: dense INT8 multi-lane MAC (dot product step).
//
//   acc_o = acc_i + sum_{lane=0..Lanes-1} (valid[lane] ? a[lane]*b[lane] : 0)
//
// Pure combinational; synthesizable. Lanes is the replication unit for the
// sequential GEMM engine (banked A/B tiles feed one product per lane/cycle).
//
// ---------------------------------------------------------------------------
// Reduction is a balanced TREE, depth ceil(log2(Lanes)), not a chain
// ---------------------------------------------------------------------------
// The first version reduced with `partial[l+1] = partial[l] + prod[l]`, a
// linear chain of `Lanes` 32-bit adders. At the live PeLanes=256 that is 256
// carry-propagate adds in one combinational path -- of the order of 25 ns even
// at an optimistic 100 ps per add, so roughly 39 MHz against a 1.0 GHz island
// clock. The old header called it a "tree of depth ~Lanes", which is two
// errors at once: it was not a tree, and a tree is depth log2(Lanes).
//
// A tree is depth 8 at Lanes=256, about a 30x reduction.
//
// The restructuring is exactly bit-identical, and that is the reason it is
// safe to do before any other datapath work: two's-complement wrapping
// addition is ASSOCIATIVE, so regrouping the sum cannot change the result,
// including when it overflows. The existing GEMM goldens are therefore the
// regression test for this change rather than merely a smoke test -- any
// difference in C, or in cycle count, is a bug in the restructuring.
//
// Ordering rationale, bandwidth analysis for the other numeric formats, and
// why this had to come before adding any of them:
// architecture/ai-matrix/numeric-formats-datapath.md.
//
// Still combinational. Depth-8 of 32-bit add plus an 8x8 multiply does not fit
// a 1 ns budget either, so a pipelined PE is the next step (F0b) -- that one
// changes the sequencer, which consumes `acc_o` in the same cycle, so it is
// deliberately separate from this bit-identical change.

module g6lc_ai_pe_dot #(
    parameter int unsigned Lanes = 4
) (
    input  logic signed [7:0]  a_i     [Lanes],
    input  logic signed [7:0]  b_i     [Lanes],
    input  logic               valid_i [Lanes],
    // Pure sum of products for this step. The accumulator is NOT here.
    //
    // The module used to expose `acc_i`/`acc_o` and compute `acc_i + tree`.
    // That is removed rather than kept for compatibility, because it is an
    // actively misleading place to pipeline: `acc_q <= acc_i + tree` with
    // `acc_i == acc_q` is a recurrence, so a register on `acc_o` feeds a stale
    // accumulator into the next step and silently drops terms. A future reader
    // looking for "the obvious output to register" must not find one here.
    //
    // The reduction is a pure function of the operands; the accumulator is
    // state, and state belongs to the sequencer. So F0b-2's pipeline stage sits
    // on this output, in g6lc_ai_gemm_seq:
    //
    //   sum_q <= sum_o
    //   acc_q <= (first ? '0 : acc_q) + sum_q
    output logic        [31:0] sum_o
);

  // Tree levels needed to reduce `Lanes` products to one.
  localparam int unsigned Levels = (Lanes <= 1) ? 1 : $clog2(Lanes);

  // Multiply AND reduce in ONE always_comb, with no intermediate signal.
  //
  // This shape was arrived at after three attempts that were all functionally
  // wrong in the same silent way -- the cone evaluated once and never
  // re-converged, so the PE returned the previous stimulus's sum after its
  // inputs changed. A stale combinational output is indistinguishable from
  // latched state in a module that has none, which is an expensive symptom to
  // chase; it was blamed on the testbench twice before the RTL. What failed:
  //
  //   1. a rectangular `level[Levels+1][NodeMax]` array -- every level both
  //      reads and writes `level`, so the array appears to depend on itself;
  //   2. one exactly-sized signal per generate level, read across scopes as
  //      `gen_lvl[v-1].node[i]` -- legal SV, but the cross-scope hierarchical
  //      reference defeats the dependency graph just as thoroughly;
  //   3. keeping the products in an UNPACKED array `prod[Lanes]` driven by
  //      generate `assign`s and read by the reduction block. Element-wise
  //      continuous assignment into an unpacked array is the specific pattern
  //      that is not tracked, so the reduction never saw new products.
  //
  // Reading the input ports directly inside one procedural block leaves a
  // single unambiguous dependency (a_i, b_i, valid_i, acc_i) and an explicit
  // evaluation order, so none of the three failure modes is expressible. The
  // loops are bounded by the `Lanes` parameter and unroll in synthesis; the
  // result is a depth-ceil(log2(Lanes)) adder tree.
  //
  // Keep it as one block with no intermediate array.
  logic signed [31:0] tree_sum;

  always_comb begin
    automatic logic signed [31:0] node [Lanes];
    automatic int unsigned cnt;

    for (int unsigned l = 0; l < Lanes; l++)
      node[l] = valid_i[l]
              ? (32'($signed(a_i[l])) * 32'($signed(b_i[l])))
              : 32'sd0;

    cnt = Lanes;
    while (cnt > 1) begin
      for (int unsigned i = 0; i < cnt / 2; i++) node[i] = node[2*i] + node[2*i+1];
      // Odd tail: promote unchanged, which keeps a non-power-of-two `Lanes`
      // exact without introducing a zero term.
      if (cnt % 2 == 1) node[cnt/2] = node[cnt-1];
      cnt = (cnt + 1) / 2;
    end

    tree_sum = node[0];
  end

  assign sum_o = tree_sum;

  // pragma translate_off
  // Guard the unused upper entries of the ragged `level` array: only the first
  // CntOut of each level are driven, and a reader of the rest would be reading
  // X. Nothing in this module reads them, so this is a lint/aid statement
  // rather than a functional one.
  initial begin
    assert (Lanes >= 1) else $error("g6lc_ai_pe_dot: Lanes must be >= 1");
  end
  // pragma translate_on

endmodule
