// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// rfix131a-02: g6lc_ctx_barrier, exhaustive. For every lane count and every
// (hold, valid, csr) pattern the kept lanes must be exactly: none while a
// CSR-class instruction is in flight; otherwise every lane up to and
// including the first valid CSR-class lane. Three properties are checked
// separately from the reference so a wrong reference cannot hide a wrong
// DUT: (1) nothing is kept under hold, (2) no lane behind a valid CSR-class
// lane is kept, (3) a lane with no valid CSR-class lane below it is kept.
module g6lc_hyp8_ctx_barrier_case #(
    parameter int unsigned N = 2
) (
    input  logic clk_i,
    output logic done_o
);
  logic         hold;
  logic [N-1:0] valid, csr, keep;
  g6lc_ctx_barrier #(.NrLanes(N)) dut (
      .hold_i(hold), .lane_valid_i(valid), .lane_csr_i(csr), .keep_o(keep));

  int unsigned checks;
  initial begin
    logic [N-1:0] ref_keep, below;
    bit           older_csr;
    done_o = 0;
    checks = 0;
    for (int unsigned h = 0; h < 2; h++) begin
      for (longint unsigned v = 0; v < (64'd1 << N); v++) begin
        for (longint unsigned c = 0; c < (64'd1 << N); c++) begin
          hold  = 1'(h);
          valid = N'(v);
          csr   = N'(c);
          #1;
          older_csr = 0;
          for (int unsigned p = 0; p < N; p++) begin
            ref_keep[p] = !hold && !older_csr;
            if (valid[p] && csr[p]) older_csr = 1;
          end
          assert (keep === ref_keep)
            else $fatal(1, "CTX_BARRIER n=%0d hold=%b valid=%b csr=%b keep=%b ref=%b",
                        N, hold, valid, csr, keep, ref_keep);
          if (hold) assert (keep === '0)
            else $fatal(1, "CTX_BARRIER hold leaks n=%0d keep=%b", N, keep);
          // Same two properties stated per lane with a mask instead of the
          // running flag the reference uses.
          for (int unsigned p = 1; p < N; p++) begin
            below = (N'(1) << p) - N'(1);
            if (|(valid & csr & below))
              assert (!keep[p])
                else $fatal(1, "CTX_BARRIER lane %0d behind a CSR lane kept n=%0d", p, N);
            else if (!hold)
              assert (keep[p])
                else $fatal(1, "CTX_BARRIER lane %0d dropped without cause n=%0d", p, N);
          end
          checks++;
        end
      end
    end
    @(posedge clk_i);
    $display("CTX_BARRIER_CASE_PASS lanes=%0d checks=%0d", N, checks);
    done_o = 1;
  end
endmodule

module tb_g6lc_hyp8_ctx_barrier;
  logic clk = 0;
  logic [3:0] done;
  always #5 clk = ~clk;
  g6lc_hyp8_ctx_barrier_case #(.N(1)) n1 (clk, done[0]);
  g6lc_hyp8_ctx_barrier_case #(.N(2)) n2 (clk, done[1]);
  g6lc_hyp8_ctx_barrier_case #(.N(4)) n4 (clk, done[2]);
  g6lc_hyp8_ctx_barrier_case #(.N(8)) n8 (clk, done[3]);
  initial begin
    wait (&done);
    $display("HYP8_CTX_BARRIER_PASS cases=4");
    $finish;
  end
  initial begin
    #100000000;
    $fatal(1, "CTX_BARRIER_WATCHDOG");
  end
endmodule
