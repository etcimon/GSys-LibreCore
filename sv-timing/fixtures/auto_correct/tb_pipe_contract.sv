// Copyright (c) 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Protocol witness for the `svt-pipe` contract (A123): drives `DUT`
// (`pipe_contract` or its emitted twin, selected by `+dut=`) with random
// operations, cancels and flushes, and checks — independently of latency —
// that every emerging result belongs to an issued, never-cancelled,
// never-flushed operation, carries that operation's id and value exactly
// once, and that every such operation emerges. A killed or flushed op that
// emerges, a wrong value, a duplicate or a lost op is an error.
module tb_pipe_contract;
  logic clk_i = 0, rst_ni = 0;
  always #5 clk_i = ~clk_i;
  logic flush_i, valid_i;
  logic [3:0] tid_i;
  logic [15:0] cancel_i;
  logic [1:0] op_i;
  logic [31:0] a_i, b_i, c_i;
  logic res_valid_o;
  logic [3:0] res_tid_o;
  logic [31:0] res_o;

`ifdef SVT_REPRESENTATION
`ifdef SVT_TWIN
  pipe_representation_svt dut (.*);
`else
  pipe_representation dut (.*);
`endif
`else
`ifdef SVT_TWIN
  pipe_contract_svt dut (.*);
`else
  pipe_contract dut (.*);
`endif
`endif

  // reference: the pure function of the operation
  function automatic logic [31:0] f(input logic [31:0] a, b, c, input logic [1:0] op);
    logic [31:0] s1, s2, s3;
`ifdef SVT_REPRESENTATION
    return (a + b) + c;
`else
    s1 = a + b;
    s2 = s1 + c;
    s3 = s2 + {op, a[29:0]};
    return (s3[31] ^ s3[0]) ? s3 : ~s3;
`endif
  endfunction

  // in-flight bookkeeping per tid: issued value, live, killed
  logic [15:0] live, killed;
  logic [31:0] expect_val [16];
  int unsigned issued = 0, emerged = 0, kills = 0, flushes = 0, errors = 0, cyc = 0;
  int unsigned seed = 7;

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 7;
    void'($urandom(seed));
    live = '0; killed = '0;
    flush_i = 0; valid_i = 0; tid_i = 0; cancel_i = 0; op_i = 0; a_i = 0; b_i = 0; c_i = 0;
    #17 rst_ni = 1;
  end

  // stimulus on the negative edge
  always @(negedge clk_i) if (rst_ni) begin
    logic [31:0] r;
    r = $urandom;
    cancel_i = (r[7:0] < 8'd40) ? ($urandom & $urandom) : '0;
    flush_i = (r[15:8] < 8'd5);
    valid_i = (r[23:16] < 8'd160);
    tid_i = r[27:24];
    // a tid may be reissued only once its previous op is no longer live
    if (valid_i && live[tid_i] && !cancel_i[tid_i] && !flush_i) valid_i = 1'b0;
    op_i = $urandom; a_i = $urandom; b_i = $urandom; c_i = $urandom;
    if (cyc >= 200000) begin
      valid_i = 0; flush_i = 0; cancel_i = '0;
    end
  end

  // bookkeeping and checks on the positive edge
  always @(posedge clk_i) if (rst_ni) begin
    cyc++;
`ifdef SVT_TRACE
    if (cyc < 40)
      $display("cyc=%0d valid_i=%b tid_i=%0d cancel=%h flush=%b | valid_q=%b p1_v=%b p2_v=%b res_valid_d=%b res_valid_o=%b res_tid_o=%0d",
               cyc, valid_i, tid_i, cancel_i, flush_i, dut.valid_q, dut.pipe_svt_p1_v, dut.pipe_svt_p2_v, dut.res_valid_d, res_valid_o, res_tid_o);
`endif
    // results emerging this cycle
    if (res_valid_o) begin
      emerged++;
      if (!live[res_tid_o]) begin
        $display("ERROR cyc=%0d: result for tid %0d that is not live (killed/flushed/never issued)", cyc, res_tid_o); errors++;
      end else if (killed[res_tid_o]) begin
        $display("ERROR cyc=%0d: result for killed tid %0d", cyc, res_tid_o); errors++;
      end else if (res_o !== expect_val[res_tid_o]) begin
        $display("ERROR cyc=%0d: tid %0d value %h expected %h", cyc, res_tid_o, res_o, expect_val[res_tid_o]); errors++;
      end
      live[res_tid_o] = 1'b0;
    end
    // kills and flushes apply to everything in flight (sampled this edge)
    if (flush_i) begin
      flushes++;
      live = '0; killed = '0;
    end else begin
      for (int t = 0; t < 16; t++) if (cancel_i[t] && live[t]) begin kills++; live[t] = 1'b0; end
    end
    // a new issue (after the kill/flush of this edge, as the DUT's input stage does)
    if (valid_i && !flush_i && !cancel_i[tid_i]) begin
      issued++;
      live[tid_i] = 1'b1; killed[tid_i] = 1'b0;
      expect_val[tid_i] = f(a_i, b_i, c_i, op_i);
    end
    if (errors > 8) $fatal(1, "FAIL tb_pipe_contract errors=%0d", errors);
    if (cyc == 200032) begin
      if (live != '0 || emerged == 0 || kills == 0 || flushes == 0 || errors != 0)
        $fatal(1, "FAIL drain/live=%h emerged=%0d kills=%0d flushes=%0d errors=%0d",
               live, emerged, kills, flushes, errors);
      $display("%s tb_pipe_contract cycles=%0d issued=%0d emerged=%0d kills=%0d flushes=%0d errors=%0d",
               errors == 0 ? "PASS" : "FAIL", cyc, issued, emerged, kills, flushes, errors);
      $finish;
    end
  end
endmodule
