// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// Address ownership and atomic-group capacity, independent of table placement.
module g6lc_hyp8_csr_credit_case #(
    parameter int unsigned Ports = 2
) (
    input logic clk_i,
    output logic done_o
);
  function automatic config_pkg::g6lc_cfg_t make_cfg();
    config_pkg::g6lc_user_cfg_t user_cfg;
    user_cfg = g6lc_config_pkg::g6lc_cfg;
    user_cfg.OoOEn = 1'b1;
    user_cfg.NrIssuePorts = Ports;
    user_cfg.SuperscalarEn = (Ports > 1);
    return build_config_pkg::build_config(user_cfg);
  endfunction
  localparam config_pkg::g6lc_cfg_t C = make_cfg();
  localparam int unsigned SB = C.NR_SB_ENTRIES;
  localparam int unsigned IDB = C.TRANS_ID_BITS;
  localparam int unsigned Capacity = (Ports > 2) ? Ports : 2;
`ifdef G6LC_HYP8_CSR_SMALL_ONLY
  // The pre-repair package has no CSR sizing helper; its 1/2-port seam is 2 bits.
  localparam int unsigned CW = 2;
`else
  localparam int unsigned CW = g6lc_ooo_pkg::ooo_csr_credit_bits(C);
`endif
  typedef struct packed {
    logic [C.XLEN-1:0] operand_a, operand_b;
    logic [IDB-1:0] trans_id;
  } fu_data_t;

  logic rst_n = 0, flush, commit, csr_valid, ready;
  logic [SB-1:0] cancelled;
  logic [Ports-1:0] disp_valid;
  logic [Ports-1:0][IDB-1:0] disp_tid;
  logic [Ports-1:0][11:0] disp_addr;
  logic [IDB-1:0] commit_tid;
  logic [CW-1:0] credit;
  logic [11:0] addr;
  logic [C.XLEN-1:0] result;
  fu_data_t fu_data;
  csr_buffer #(.G6LCCfg(C), .fu_data_t(fu_data_t)) dut (
    .clk_i, .rst_ni(rst_n), .flush_i(flush), .cancelled_mask_i(cancelled),
    .sb_live_i({SB{1'b1}}), .disp_valid_i(disp_valid),
    .disp_tid_i(disp_tid), .disp_addr_i(disp_addr), .csr_credit_o(credit),
    .fu_data_i(fu_data), .csr_ready_o(ready), .csr_valid_i(csr_valid),
    .csr_result_o(result), .csr_commit_i(commit),
    .csr_commit_tid_i(commit_tid), .csr_addr_o(addr)
  );

  bit [SB-1:0] owned;
  logic [11:0] address_by_tid [SB];
  bit [Ports-1:0] next_valid;
  logic [Ports-1:0][IDB-1:0] next_tid;
  logic [Ports-1:0][11:0] next_addr;
  bit [SB-1:0] next_cancel;
  bit next_flush, next_commit;
  int unsigned next_lookup, rounds, checks;
  int unsigned rng = 32'h9e3779b9 ^ 32'(Ports);

  function automatic int unsigned random_word();
    rng ^= rng << 13;
    rng ^= rng >> 17;
    rng ^= rng << 5;
    return rng;
  endfunction

  task automatic clear_stimulus();
    next_valid = '0;
    next_tid = '0;
    next_addr = '0;
    next_cancel = '0;
    next_flush = 0;
    next_commit = 0;
    next_lookup = 0;
  endtask

  task automatic reset_case();
    @(negedge clk_i);
    rst_n = 0;
    disp_valid = '0;
    cancelled = '0;
    flush = 0;
    commit = 0;
    csr_valid = 0;
    fu_data = '0;
    owned = '0;
    clear_stimulus();
    repeat (3) @(negedge clk_i);
    rst_n = 1;
  endtask

  task automatic advance();
    bit [SB-1:0] swept;
    int unsigned expected_free;
    logic [11:0] expected_addr;
    @(negedge clk_i);
    disp_valid = next_valid;
    disp_tid = next_tid;
    disp_addr = next_addr;
    cancelled = next_cancel;
    flush = next_flush;
    commit = next_commit;
    commit_tid = IDB'(next_lookup);
    fu_data.trans_id = IDB'(next_lookup);
    fu_data.operand_a = C.XLEN'(random_word());
    fu_data.operand_b = ~fu_data.operand_a;
    csr_valid = owned[next_lookup] && !commit && !flush && (rounds % 3 == 0);
    swept = owned & ~next_cancel;
    if (next_commit) begin
      assert (owned[next_lookup]) else $fatal(1, "bench: commit has no owner");
      swept[next_lookup] = 0;
    end
    expected_free = Capacity - $countones(swept);
    expected_addr = owned[next_lookup] ? address_by_tid[next_lookup] : '0;
    #1;
    assert (32'($unsigned(credit)) == expected_free)
      else $fatal(1, "CSR_CREDIT ports=%0d credit=%0d expected=%0d",
                  Ports, credit, expected_free);
    assert (ready && addr === expected_addr && result === fu_data.operand_a)
      else $fatal(1, "CSR_IDENTITY ports=%0d tid=%0d addr=%h expected=%h",
                  Ports, next_lookup, addr, expected_addr);
    checks += 2;
    @(posedge clk_i);
    #1;
    owned = swept;
    if (next_flush) owned = '0;
    else for (int unsigned p = 0; p < Ports; p++) begin
      if (next_valid[p] && !next_cancel[next_tid[p]]) begin
        assert (!owned[next_tid[p]])
          else $fatal(1, "bench: duplicate dispatch owner");
        owned[next_tid[p]] = 1;
        address_by_tid[next_tid[p]] = next_addr[p];
      end
    end
    assert ($countones(owned) <= Capacity) else $fatal(1, "bench: over-credit");
    rounds++;
  endtask

  initial begin : exercise
    bit [SB-1:0] available, swept;
    int unsigned remaining, index;
    done_o = 0;
    rounds = 0;
    checks = 0;
    disp_tid = '0;
    disp_addr = '0;
    commit_tid = '0;
    reset_case();

    // Full legal groups must fit. The model never uses the DUT's depth helper.
    for (int unsigned base = 0; base < Capacity; base += Ports) begin
      clear_stimulus();
      for (int unsigned p = 0; p < Ports; p++) if (base + p < Capacity) begin
        next_valid[p] = 1;
        next_tid[p] = IDB'(base + p);
        next_addr[p] = 12'(32'h200 + base + p);
      end
      advance();
    end
    // Two distant holes expose incomplete lowest-free prefix propagation.
    clear_stimulus();
    next_cancel[0] = 1;
    next_cancel[Capacity-1] = 1;
    next_valid[0] = 1;
    next_tid[0] = IDB'(Capacity);
    next_addr[0] = 12'h321;
    advance();
    clear_stimulus();
    next_lookup = Capacity;
    advance();  // Lookup must not require a retirement strobe.
    clear_stimulus();
    next_lookup = Capacity;
    next_commit = 1;
    next_valid[0] = 1;
    next_tid[0] = IDB'(Capacity + 1);
    next_addr[0] = 12'h345;
    advance();
    clear_stimulus();
    next_cancel[Capacity+2] = 1;
    next_valid[0] = 1;
    next_tid[0] = IDB'(Capacity + 2);
    next_addr[0] = 12'h367;
    advance();  // A cancelled arrival consumes no entry.

    for (int unsigned n = 0; n < 4000; n++) begin
      if (n == 2000) reset_case();
      clear_stimulus();
      index = random_word() % SB;
      for (int unsigned i = 0; i < SB; i++)
        if (owned[(index+i) % SB]) begin
          next_lookup = (index+i) % SB;
          break;
        end
      next_commit = owned[next_lookup] && ((random_word() % 3) == 0);
      next_flush = ((random_word() % 97) == 0);
      for (int unsigned i = 0; i < SB; i++)
        if (owned[i] && ((random_word() % 11) == 0)) next_cancel[i] = 1;
      swept = owned & ~next_cancel;
      if (next_commit) swept[next_lookup] = 0;
      remaining = Capacity - $countones(swept);
      available = ~owned & ~next_cancel;
      for (int unsigned p = 0; p < Ports; p++)
        if (!next_flush && remaining != 0 && ((random_word() & 1) != 0)) begin
          index = random_word() % SB;
          for (int unsigned i = 0; i < SB; i++) if (available[(index+i) % SB]) begin
            next_valid[p] = 1;
            next_tid[p] = IDB'((index+i) % SB);
            next_addr[p] = 12'(random_word());
            available[(index+i) % SB] = 0;
            remaining--;
            break;
          end
        end
      advance();
    end
    clear_stimulus();
    next_flush = 1;
    advance();
    $display("CSR_CREDIT_CASE_PASS ports=%0d slots=%0d bits=%0d cycles=%0d checks=%0d",
             Ports, dut.DEPTH, $bits(credit), rounds, checks);
    done_o = 1;
  end
endmodule

module tb_g6lc_hyp8_csr_credit;
  logic clk = 0;
  logic [4:0] done;
  always #5 clk = ~clk;
  g6lc_hyp8_csr_credit_case #(.Ports(1)) p1(clk, done[0]);
  g6lc_hyp8_csr_credit_case #(.Ports(2)) p2(clk, done[1]);
`ifdef G6LC_HYP8_CSR_SMALL_ONLY
  assign done[4:2] = '1;
  localparam int Cases = 2;
`else
  g6lc_hyp8_csr_credit_case #(.Ports(3)) p3(clk, done[2]);
  g6lc_hyp8_csr_credit_case #(.Ports(4)) p4(clk, done[3]);
  g6lc_hyp8_csr_credit_case #(.Ports(8)) p8(clk, done[4]);
  localparam int Cases = 5;
`endif
  initial begin
    wait (&done);
    $display("HYP8_CSR_CREDIT_PASS cases=%0d", Cases);
    $finish;
  end
  initial begin
    repeat (20000) @(posedge clk);
    $fatal(1, "CSR_CREDIT_WATCHDOG");
  end
endmodule
