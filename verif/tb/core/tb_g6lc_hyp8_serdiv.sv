// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon
// serdiv leaf: random udiv/urem/div/rem traffic with out_rdy back-
// pressure and ~5% flush pulses against a RISC-V-semantics oracle;
// per-transaction accept->out_vld latency is summed into the PASS
// token so an exact timing rewrite must reproduce lat_sum.
module tb_g6lc_hyp8_serdiv;
  localparam config_pkg::g6lc_cfg_t C =
      build_config_pkg::build_config(g6lc_config_pkg::g6lc_cfg);
  localparam int unsigned IDB = C.TRANS_ID_BITS;
  int NTX = 20000;

  logic clk = 0, rst_n = 0;
  always #2.5 clk = ~clk;

  logic [IDB-1:0]  id_i, id_o;
  logic [63:0]     op_a, op_b, res;
  logic [1:0]      opcode;
  logic            in_vld, in_rdy, flush, out_vld, out_rdy;

  serdiv #(.G6LCCfg(C), .WIDTH(64)) dut (
    .clk_i(clk), .rst_ni(rst_n),
    .id_i(id_i), .op_a_i(op_a), .op_b_i(op_b), .opcode_i(opcode),
    .in_vld_i(in_vld), .in_rdy_o(in_rdy), .flush_i(flush),
    .out_vld_o(out_vld), .out_rdy_i(out_rdy), .id_o(id_o), .res_o(res)
  );

  task automatic drive(); @(negedge clk); endtask

  // RISC-V oracle: udiv/urem b=0 -> all-ones / a; div/rem b=0 -> a / all-ones;
  // div/rem overflow (INT_MIN/-1) -> a / 0.
  // Signed results are formed in signed temporaries first: a ternary
  // with an unsigned literal arm would make `sa / sb` unsigned.
  function automatic logic [63:0] oracle(input logic [63:0] a,
                                         input logic [63:0] b,
                                         input logic [1:0]       opc);
    logic signed [63:0] sa, sb, sq, sr;
    sa = a; sb = b;
    sq = (sb == 0) ? -64'sd1 : ((sa == 64'sh8000000000000000 && sb == -64'sd1) ? sa : (sa / sb));
    sr = (sb == 0) ? sa : ((sa == 64'sh8000000000000000 && sb == -64'sd1) ? 64'sd0 : (sa % sb));
    case (opc)
      2'd0: return (b == 0) ? 64'hffffffffffffffff : (a / b);
      2'd2: return (b == 0) ? a : (a % b);
      2'd1: return sq;
      2'd3: return sr;
      default: return '0;
    endcase
  endfunction

  int ntx, lat_sum, exp_lat, fails, cyc;
  initial cyc = 0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (cyc > 2000000) begin $display("SERDIV_WATCHDOG"); $finish; end
  end
  logic [63:0] exp_res; logic [IDB-1:0] exp_id;
  bit in_flight;

  // Accept protocol (mult.sv: div_in_fire = div_valid_op && div_idle_q):
  // in_rdy_o is high only while the unit is IDLE and in_vld_i is low
  // (STABLE_HANDSHAKE=0 deasserts it in the accept cycle), so wait for
  // in_rdy with in_vld low, then pulse in_vld for one edge.
  task automatic issue(input logic [63:0] a, input logic [63:0] b,
                       input logic [1:0] opc);
    in_vld = 0; out_rdy = 1;   // drain any pending FINISH
    exp_lat = 0;
    while (!in_rdy) begin drive(); exp_lat++; if (exp_lat>5000) begin $display("SERDIV_NO_RDY"); $finish; end end
    op_a = a; op_b = b; opcode = opc; id_i = IDB'(ntx);
    in_vld = 1;
    drive();                   // accepted at this posedge
    in_vld = 0;
    exp_res = oracle(a, b, opc); exp_id = IDB'(ntx); exp_lat = 0;
    in_flight = 1;
  endtask

  logic [63:0] ra, rb; logic [1:0] ropc;
  int flushes;
  bit flushed;
  initial begin
    in_vld = 0; out_rdy = 1; flush = 0; in_flight = 0; fails = 0; lat_sum = 0; flushes = 0;
    void'($value$plusargs("ntx=%d", NTX));
    repeat (4) drive(); rst_n = 1; drive();
    ntx = 0;
    while (ntx < NTX) begin
      // random operand shape
      ra = {$urandom, $urandom}; rb = {$urandom, $urandom}; ropc = $urandom % 4;
      case ($urandom % 8)
        1: rb = 0;
        2: begin ra = 64'h8000000000000000; rb = 64'hffffffffffffffff; end
        3: ra = 0;
        4: begin ra = $urandom % 1000; rb = 64'hffffffffffffffff; end
        5: rb = 64'd1 << ($urandom % 63);
        6: begin ra = 64'hffffffffffffffff; rb = 64'h8000000000000000; end
        default: ;
      endcase
      issue(ra, rb, ropc);
      // wait for the result (counting latency); ~2% of the cycles
      // mid-flight pulse flush_i -- the unit must drop to IDLE with no
      // result, and the transaction is re-issued.
      flushed = 0;
      out_rdy = (($urandom % 4) != 0);
      while (!(out_vld && out_rdy)) begin
        if (($urandom % 50) == 0) begin
          flush = 1; drive(); flush = 0; flushes++;
          flushed = 1;
          break;
        end
        drive();
        exp_lat++;
        if (exp_lat > 200) begin fails++; $display("SERDIV_TIMEOUT n=%0d", ntx); break; end
        out_rdy = (($urandom % 4) != 0);
      end
      if (flushed) begin
        // no stale result may appear after a flush
        repeat (3) begin drive(); if (out_vld) begin fails++; $display("SERDIV_STALE_AFTER_FLUSH n=%0d", ntx); end end
        in_flight = 0;
        continue;   // re-issue the same ntx
      end
      if (out_vld && out_rdy) begin
        if (res !== exp_res || id_o !== exp_id) begin
          fails++;
          $display("SERDIV_MIS n=%0d a=%h b=%h opc=%0d got=%h/%0d want=%h/%0d",
                   ntx, ra, rb, ropc, res, id_o, exp_res, exp_id);
        end
        lat_sum += exp_lat;
        in_flight = 0;
      end
      ntx++;
    end
    if (fails == 0)
      $display("HYP8_SERDIV_PASS n=%0d flushes=%0d lat_sum=%0d", ntx, flushes, lat_sum);
    else
      $display("HYP8_SERDIV_FAIL n=%0d fails=%0d", ntx, fails);
    $finish;
  end
endmodule
