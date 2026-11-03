// SPDX-License-Identifier: MIT
// g6lc_apu_doneq: completion queue unit test.  Directed arms collide
// two, three and all four sources in one cycle (the vgtop session
// corpus never does), then a seeded random stream bounded by the
// in-flight budget checks order, payload and count against a reference
// FIFO.  Priority order within a cycle is source 0,1,2,3.
module tb_g6lc_apu_doneq;
  localparam int unsigned Depth = 8;
  typedef logic [15:0] pl_t;
  logic clk = 0, rst_n = 0;
  logic [3:0] push;
  pl_t  [3:0] pl;
  logic pop;
  pl_t  pl_o;
  logic [2:0] push_n;
  int unsigned checks = 0, errors = 0, cases = 0, cycles = 0;
  pl_t ref_q[$];
  int unsigned inflight = 0;
  int unsigned seq = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cycles++;

  g6lc_apu_doneq #(.Depth(Depth), .pl_t(pl_t)) dut (
    .clk_i(clk), .rst_ni(rst_n), .push_i(push), .pl_i(pl),
    .pop_o(pop), .pl_o(pl_o), .push_n_o(push_n));

  task automatic check(input bit ok, input string what);
    checks++;
    if (!ok) begin
      errors++;
      $display("FAIL %s (t=%0d)", what, cycles);
    end
  endtask

  // one cycle: drive `m`, compare the popped head against the model,
  // then enqueue this cycle's pushes in priority order
  task automatic step(input logic [3:0] m);
    push = m;
    for (int s = 0; s < 4; s++) pl[s] = pl_t'({s[1:0], 14'(seq + s)});
    #1;
    check(push_n == 3'($countones(m)), "push_n");
    if (pop) begin
      check(ref_q.size() != 0, "pop with empty model");
      if (ref_q.size() != 0) begin
        check(pl_o == ref_q[0], $sformatf("order: got %h exp %h", pl_o,
                                          ref_q[0]));
        void'(ref_q.pop_front());
      end
    end else
      check(ref_q.size() == 0, "model non-empty but queue idle");
    for (int s = 0; s < 4; s++)
      if (m[s]) ref_q.push_back(pl[s]);
    seq += 4;
    @(posedge clk);
    #1;
  endtask

  task automatic drain;
    int unsigned n = 0;
    while (ref_q.size() != 0 && n < 4 * Depth) begin
      step(4'b0000);
      n++;
    end
    step(4'b0000);
    check(ref_q.size() == 0 && !pop, "drained");
  endtask

  initial begin
    push = '0; pl = '0;
    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk); #1;

    // directed collisions
    cases++; step(4'b0011); drain();          // shader + xfer
    cases++; step(4'b0110); drain();          // xfer + raster
    cases++; step(4'b1001); drain();          // shader + external
    cases++; step(4'b0111); drain();          // three engines
    cases++; step(4'b1111); drain();          // all four, one cycle
    // back-to-back full collisions while the queue is draining: 4 in,
    // 1 out per cycle, stays inside Depth-1 for one extra burst
    cases++; step(4'b1111); step(4'b0000); step(4'b0011); drain();

    // seeded random stream: each source keeps at most one completion
    // outstanding before the consumer has drained (the in-flight budget
    // the vgtop depth is sized for)
    cases++;
    for (int i = 0; i < 4000; i++) begin
      logic [3:0] m = 4'($urandom_range(0, 15));
      while (m != 0 && ref_q.size() + $countones(m) > Depth - 1)
        m = m & (m - 1);
      step(m);
      if (ref_q.size() > Depth - 1) begin
        check(1'b0, "model exceeds in-flight budget (queue lost pops)");
        break;
      end
    end
    drain();

    if (errors == 0)
      $display("PASS tb_g6lc_apu_doneq cases=%0d checks=%0d cycles=%0d",
               cases, checks, cycles);
    else
      $display("FAIL tb_g6lc_apu_doneq cases=%0d checks=%0d errors=%0d",
               cases, checks, errors);
    $finish;
  end
endmodule
