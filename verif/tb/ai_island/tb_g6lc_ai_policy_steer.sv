// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

module tb_g6lc_ai_policy_steer_instance #(
  parameter bit CodecEn = 1'b0,
  parameter bit BenefitEn = 1'b0,
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinGain16ths = 2,
  parameter logic [31:0] FormatSlotsLog2 = 32'h67788098
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, valid_i,
  input logic batch_first_i, batch_last_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [2:0] opcode_i, numfmt_i,
  input logic [1:0] balance_i,
  input logic [255:0] sample_i,
  input logic sample_valid_i, exact_zero_i,
  input logic [63:0] next_addr_i,
  input logic next_addr_valid_i, mispredict_i,
  output logic ready_o, work_valid_o,
  output logic [2:0] code_o, next_code_o, numfmt_o,
  output logic [16:0] policy_o, next_policy_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic warm_valid_o,
  output logic [63:0] warm_addr_o,
  output logic [3:0] warm_bank_o,
  output logic residual_skip_o, eval_o, commit_o, hold_o, predict_hit_o, predict_miss_o
);
  function automatic config_pkg::ai_cfg_t make_cfg();
    config_pkg::ai_cfg_t cfg = CodecEn ? cva6_config_pkg::ai_cfg : config_pkg::AiCfgOff;
    cfg.PolicyCodecEn = CodecEn;
    cfg.PolicyBenefitEn = BenefitEn;
    return cfg;
  endfunction
  localparam config_pkg::ai_cfg_t TestCfg = make_cfg();

  g6lc_ai_policy_steer #(
    .AiCfg(TestCfg), .ReadBytesPerCycle(ReadBytesPerCycle),
    .MinGain16ths(MinGain16ths), .FormatSlotsLog2(FormatSlotsLog2)
  ) i_steer (
    .code_o(code_o), .next_code_o(next_code_o),
    .policy_o(policy_o), .next_policy_o(next_policy_o), .topology_o(topology_o),
    .subcode_valid_o(), .subcode_evaluated_o(), .subcode_cache_hit_o(), .subcode_o(), .subcode_topology_o(),
    .subcode_baseline_cycles_o(), .subcode_selected_cycles_o(), .*
  );

`ifdef FORMAL
  logic formal_past_valid = 1'b0;
  logic [15:0] fm_q, fn_q, fk_q;
  logic [2:0] ff_q;
  logic [1:0] fb_q;
  logic fseen_q;
  int unsigned baseline_k, baseline_step;
  logic state_nonzero;
  assign state_nonzero = |{ready_o, work_valid_o, code_o, next_code_o, numfmt_o,
      (policy_o ^ 17'h03332), (next_policy_o ^ 17'h03332), topology_o,
      warm_valid_o, warm_addr_o, warm_bank_o, residual_skip_o, eval_o,
      commit_o, hold_o, predict_hit_o, predict_miss_o};
  always_comb begin
    baseline_k = 32'(fk_q);
    if (baseline_k > (32'd1 << topology_o.slots_log2))
      baseline_k = 32'd1 << topology_o.slots_log2;
    baseline_step = (32'(fm_q) + 32'(fn_q)) *
        ((baseline_k * (32'd1 << topology_o.element_bits_log2) + 7) / 8);
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fm_q <= '0;
      fn_q <= '0;
      fk_q <= '0;
      ff_q <= '0;
      fb_q <= '0;
      fseen_q <= 1'b0;
    end else if (flush_i || !enable_i) begin
      fm_q <= '0;
      fn_q <= '0;
      fk_q <= '0;
      ff_q <= '0;
      fb_q <= '0;
      fseen_q <= 1'b0;
    end else if (valid_i && ready_o) begin
      fm_q <= m_i;
      fn_q <= n_i;
      fk_q <= k_i;
      ff_q <= numfmt_i;
      fb_q <= balance_i;
      fseen_q <= 1'b1;
    end
  end
  always_ff @(posedge clk_i) begin
    formal_past_valid <= 1'b1;
    if (!formal_past_valid) assume (!rst_ni);
    if (!(CodecEn && BenefitEn)) assert (!state_nonzero);
    else if (formal_past_valid) begin
      assert (ready_o == (enable_i && !flush_i));
      assert (numfmt_o == ff_q);
      assert (topology_o == g6lc_ai_policy_pkg::policy_topology(
          g6lc_ai_policy_pkg::policy_code_t'(code_o), ff_q, fm_q, fn_q, fk_q, fb_q,
          ReadBytesPerCycle, MinGain16ths, FormatSlotsLog2));
      assert (topology_o.valid == (fseen_q && ff_q != 3'd2 &&
          fm_q != '0 && fn_q != '0 && fk_q != '0));
      assert (!residual_skip_o || (work_valid_o && numfmt_o <= 3'd1));
      assert (!(warm_valid_o || residual_skip_o) || numfmt_o != 3'd2);
      assert (!(predict_hit_o && predict_miss_o));
      assert (!(commit_o && hold_o));
      if (topology_o.apply) begin
        assert (topology_o.valid && code_o != 3'd7);
        assert (fb_q != 2'd0 || (code_o == 3'd3 &&
            (32'(fk_q) <= ((32'd1 << topology_o.slots_log2) >> 1) ||
             baseline_step >= ReadBytesPerCycle)));
        assert (32'(topology_o.rows_log2) + 32'(topology_o.cols_log2) <= 4);
        assert (fm_q >= 16'd8 || fn_q >= 16'd8);
        assert (32'(topology_o.rows_log2) + 32'(topology_o.cols_log2) +
            32'(topology_o.reduction_log2) == 32'(topology_o.slots_log2));
        assert (topology_o.rows_log2 != '0 || topology_o.cols_log2 != '0);
        assert (32'(topology_o.gain_16ths) >= MinGain16ths);
        assert ((32'(fm_q) & ((32'd1 << topology_o.rows_log2) - 1)) == 0);
        assert ((32'(fn_q) & ((32'd1 << topology_o.cols_log2) - 1)) == 0);
        assert (32'(fk_q) <= ((32'd1 << topology_o.slots_log2) >> 1) ||
            baseline_step >= ReadBytesPerCycle);
      end else begin
        assert (topology_o.rows_log2 == '0 && topology_o.cols_log2 == '0);
        assert (topology_o.gain_16ths == '0);
      end
      if (work_valid_o && $past(rst_ni && valid_i && ready_o)) begin
        if ($past(fseen_q && numfmt_i != ff_q)) begin
          assert (commit_o && eval_o && !hold_o);
          assert (!predict_hit_o && !predict_miss_o);
        end
        if (residual_skip_o) assert ($past(exact_zero_i));
      end
      if (rst_ni && $past(rst_ni && enable_i && !flush_i && !valid_i)) begin
        assert (numfmt_o == $past(numfmt_o));
        assert (topology_o == $past(topology_o));
        assert (code_o == $past(code_o));
      end
    end
  end
`endif
endmodule

module tb_g6lc_ai_policy_steer_on #(
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinGain16ths = 2,
  parameter logic [31:0] FormatSlotsLog2 = 32'h67788098
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, valid_i,
  input logic batch_first_i, batch_last_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [2:0] opcode_i, numfmt_i,
  input logic [1:0] balance_i,
  input logic [255:0] sample_i,
  input logic sample_valid_i, exact_zero_i,
  input logic [63:0] next_addr_i,
  input logic next_addr_valid_i, mispredict_i,
  output logic ready_o, work_valid_o,
  output logic [2:0] code_o, next_code_o, numfmt_o,
  output logic [16:0] policy_o, next_policy_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic warm_valid_o,
  output logic [63:0] warm_addr_o,
  output logic [3:0] warm_bank_o,
  output logic residual_skip_o, eval_o, commit_o, hold_o, predict_hit_o, predict_miss_o
);
  tb_g6lc_ai_policy_steer_instance #(
    .CodecEn(1'b1), .BenefitEn(1'b1), .ReadBytesPerCycle(ReadBytesPerCycle),
    .MinGain16ths(MinGain16ths), .FormatSlotsLog2(FormatSlotsLog2)
  ) i_on (.*);
endmodule

module tb_g6lc_ai_policy_steer #(
  parameter int unsigned ReadBytesPerCycle = 128,
  parameter int unsigned MinGain16ths = 2,
  parameter logic [31:0] FormatSlotsLog2 = 32'h67788098
) (
  input logic clk_i, rst_ni, testmode_i, enable_i, flush_i, valid_i,
  input logic batch_first_i, batch_last_i,
  input logic [15:0] m_i, n_i, k_i,
  input logic [2:0] opcode_i, numfmt_i,
  input logic [1:0] balance_i,
  input logic [255:0] sample_i,
  input logic sample_valid_i, exact_zero_i,
  input logic [63:0] next_addr_i,
  input logic next_addr_valid_i, mispredict_i,
  output logic ready_o, work_valid_o,
  output logic [2:0] code_o, next_code_o, numfmt_o,
  output logic [16:0] policy_o, next_policy_o,
  output g6lc_ai_policy_pkg::policy_topology_t topology_o,
  output logic warm_valid_o,
  output logic [63:0] warm_addr_o,
  output logic [3:0] warm_bank_o,
  output logic residual_skip_o, eval_o, commit_o, hold_o, predict_hit_o, predict_miss_o,
  output logic disabled_nonzero_o,
  input logic [2:0] probe_code_i,
  input logic [31:0] probe_read_bytes_i, probe_min_gain_i, probe_slots_i,
  output logic [63:0] normalized_o,
  output g6lc_ai_policy_pkg::policy_topology_t probe_topology_o,
  input logic resource_start_i, resource_decision_i,
  input logic [15:0] resource_m_i, resource_n_i, resource_k_i,
  input logic [2:0] resource_fmt_i, resource_rows_i, resource_cols_i,
  input logic [3:0] resource_reduction_i,
  output logic resource_busy_o, resource_done_o, resource_rejected_o,
  output logic [63:0] resource_cycles_o, resource_compute_o, resource_external_o,
  output logic [63:0] resource_macs_o, resource_reads_o, resource_operands_o,
  output logic [63:0] resource_c_o, resource_steps_o
);
  tb_g6lc_ai_policy_steer_on #(
    .ReadBytesPerCycle(ReadBytesPerCycle), .MinGain16ths(MinGain16ths),
    .FormatSlotsLog2(FormatSlotsLog2)
  ) i_enabled (.*);

  logic [1:0] off_nonzero;
  for (genvar i = 0; i < 2; i++) begin : gen_disabled
    logic off_ready, off_work, off_warm, off_skip, off_eval, off_commit, off_hold, off_hit, off_miss;
    logic [2:0] off_code, off_next, off_fmt;
    logic [16:0] off_policy, off_next_policy;
    g6lc_ai_policy_pkg::policy_topology_t off_topology;
    logic [63:0] off_addr;
    logic [3:0] off_bank;
    tb_g6lc_ai_policy_steer_instance #(.CodecEn(i == 1)) i_off (
      .clk_i, .rst_ni, .testmode_i, .enable_i, .flush_i, .valid_i,
      .batch_first_i, .batch_last_i, .m_i, .n_i, .k_i, .opcode_i, .numfmt_i,
      .balance_i, .sample_i, .sample_valid_i, .exact_zero_i, .next_addr_i,
      .next_addr_valid_i, .mispredict_i,
      .ready_o(off_ready), .work_valid_o(off_work), .code_o(off_code),
      .next_code_o(off_next), .numfmt_o(off_fmt), .policy_o(off_policy),
      .next_policy_o(off_next_policy), .topology_o(off_topology), .warm_valid_o(off_warm),
      .warm_addr_o(off_addr), .warm_bank_o(off_bank), .residual_skip_o(off_skip),
      .eval_o(off_eval), .commit_o(off_commit), .hold_o(off_hold),
      .predict_hit_o(off_hit), .predict_miss_o(off_miss)
    );
    assign off_nonzero[i] = |{off_ready, off_work, off_code, off_next, off_fmt,
        (off_policy ^ 17'h03332), (off_next_policy ^ 17'h03332), off_topology,
        off_warm, off_addr, off_bank, off_skip, off_eval, off_commit, off_hold, off_hit, off_miss};
  end
  assign disabled_nonzero_o = |off_nonzero;
  assign normalized_o = g6lc_ai_policy_pkg::policy_normalize_sample(sample_i, numfmt_i);
  assign probe_topology_o = g6lc_ai_policy_pkg::policy_topology(
      g6lc_ai_policy_pkg::policy_code_t'(probe_code_i), numfmt_i, m_i, n_i, k_i,
      balance_i, probe_read_bytes_i, probe_min_gain_i, probe_slots_i);

  tb_g6lc_ai_policy_resource #(.SramReadBytes(ReadBytesPerCycle)) i_resource (
    .clk_i, .rst_ni, .start_i(resource_start_i), .decision_i(resource_decision_i),
    .m_i(resource_m_i), .n_i(resource_n_i), .k_i(resource_k_i), .numfmt_i(resource_fmt_i),
    .rows_log2_i(resource_rows_i), .cols_log2_i(resource_cols_i),
    .reduction_log2_i(resource_reduction_i), .busy_o(resource_busy_o),
    .done_o(resource_done_o), .rejected_o(resource_rejected_o),
    .cycles_o(resource_cycles_o), .compute_cycles_o(resource_compute_o),
    .external_cycles_o(resource_external_o), .useful_macs_o(resource_macs_o),
    .read_bytes_o(resource_reads_o), .operand_bytes_o(resource_operands_o),
    .c_bytes_o(resource_c_o), .steps_o(resource_steps_o)
  );
endmodule

`ifdef G6LC_HYP8_POLICY_PIPELINE_TEST
// Hyp carry-over contract bench. The package function is the independent
// combinational reference; compare transactions at valid, never by fixed latency.
module tb_g6lc_ai_policy_pipeline;
  import g6lc_ai_policy_pkg::*;
  timeunit 1ns; timeprecision 1ps;
  logic clk = 0;
  always #5 clk = !clk;
  logic rst = 0, flush = 0, valid = 0;
  logic [15:0] m = 0, n = 0, k = 0;
  logic [2:0] fmt = 0;
  logic [1:0] balance = 1;
  logic [2:0] topo_valid;
  policy_topology_t topologies [3][8];
  localparam logic [31:0] CustomSlots = 32'h11111011;
  for (genvar g = 0; g < 3; g++) begin : gen_topology
    g6lc_ai_policy_topology #(
      .ReadBytesPerCycle(g == 1 ? 4096 : 128),
      .FormatSlotsLog2(g == 2 ? CustomSlots : 32'h67788098)
    ) i_dut (.clk_i(clk), .rst_ni(rst), .flush_i(flush), .valid_i(valid),
      .m_i(m), .n_i(n), .k_i(k), .numfmt_i(fmt), .balance_i(balance),
      .valid_o(topo_valid[g]), .topology_o(topologies[g]));
  end
  function automatic config_pkg::ai_cfg_t cfg();
    config_pkg::ai_cfg_t c = config_pkg::AiCfgOff;
    c.MatrixEn = 1; c.Queues = 1;
    c.PolicyCodecEn = 1; c.PolicyBenefitEn = 1;
    c.PolicySubcodeEn = 1; c.PolicySubcodeCacheEn = 1;
    return c;
  endfunction
  logic s_valid = 0, s_flush = 0, s_enable = 1, s_ready, s_work;
  logic s_first = 1, s_last = 1, s_commit, s_hold, s_eval;
  logic [15:0] sm = 0, sn = 0, sk = 0;
  logic [2:0] sfmt = 0, published_fmt;
  logic s_next_valid = 0, s_warm;
  logic [63:0] s_next_addr = 0, s_warm_addr;
  policy_code_t s_code, next_code;
  policy_t s_policy, next_policy;
  policy_topology_t s_topology, sub_topology;
  logic sub_valid, sub_hit, sub_eval;
  logic [2:0] sub_code;
  logic [31:0] sub_base, sub_selected;
  g6lc_ai_policy_steer #(.AiCfg(cfg())) i_steer (
    .clk_i(clk), .rst_ni(rst), .testmode_i(1'b0), .enable_i(s_enable),
    .flush_i(s_flush), .valid_i(s_valid), .batch_first_i(s_first), .batch_last_i(s_last),
    .m_i(sm), .n_i(sn), .k_i(sk), .opcode_i(3'd0), .balance_i(2'd1), .numfmt_i(sfmt),
    .sample_i('0), .sample_valid_i(1'b0), .exact_zero_i(1'b0),
    .next_addr_i(s_next_addr), .next_addr_valid_i(s_next_valid), .mispredict_i(1'b0),
    .ready_o(s_ready), .work_valid_o(s_work), .code_o(s_code), .next_code_o(next_code),
    .policy_o(s_policy), .next_policy_o(next_policy),
    .warm_valid_o(s_warm), .warm_addr_o(s_warm_addr), .warm_bank_o(), .residual_skip_o(),
    .eval_o(s_eval), .commit_o(s_commit), .hold_o(s_hold),
    .predict_hit_o(), .predict_miss_o(), .numfmt_o(published_fmt), .topology_o(s_topology),
    .subcode_valid_o(sub_valid), .subcode_evaluated_o(sub_eval), .subcode_cache_hit_o(sub_hit),
    .subcode_o(sub_code), .subcode_topology_o(sub_topology),
    .subcode_baseline_cycles_o(sub_base), .subcode_selected_cycles_o(sub_selected)
  );
  logic p_start = 0, p_done = 0, p_cancel = 0, p_valid = 0, p_ready;
  logic [31:0] p_data = 0, p_snapshot;
  g6lc_ai_policy_publish #(.Width(32)) i_publish (
    .clk_i(clk), .rst_ni(rst), .start_i(p_start), .done_i(p_done), .cancel_i(p_cancel),
    .result_valid_i(p_valid), .result_i(p_data), .ready_o(p_ready), .snapshot_o(p_snapshot)
  );
  int topology_checks = 0, publication_checks = 0, flush_checks = 0;
  task automatic tick;
    @(posedge clk); #1;
  endtask
  task automatic topology_job(input int mm, nn, kk, ff, bb);
    logic [2:0] seen;
    policy_topology_t expected;
    @(negedge clk);
    m = 16'(mm); n = 16'(nn); k = 16'(kk); fmt = 3'(ff); balance = 2'(bb);
    valid = 1; tick(); @(negedge clk); valid = 0;
    seen = '0;
    for (int cycle = 0; cycle < 60 && seen != 3'b111; cycle++) begin
      tick();
      for (int g = 0; g < 3; g++) begin
        if (topo_valid[g]) begin
          assert (!seen[g]) else $fatal(1, "duplicate topology");
          seen[g] = 1;
          for (int c = 0; c < 8; c++) begin
            expected = policy_topology(policy_code_t'(c), fmt, m, n, k, balance,
                g == 1 ? 4096 : 128, 2, g == 2 ? CustomSlots : 32'h67788098);
            assert (topologies[g][c] == expected)
              else $fatal(1, "topology g=%0d c=%0d m=%0d n=%0d k=%0d fmt=%0d got=%h want=%h",
                          g,c,m,n,k,fmt,topologies[g][c],expected);
            topology_checks++;
          end
        end
      end
    end
    assert (seen == 3'b111) else $fatal(1, "topology timeout");
  endtask
  task automatic steer_job(input int mm, nn, kk, ff, input bit first, last);
    int cycles;
    policy_topology_t expected;
    @(negedge clk);
    cycles = 0;
    while (!s_ready && cycles < 80) begin tick(); @(negedge clk); cycles++; end
    assert (s_ready) else $fatal(1, "steer admission timeout");
    sm = 16'(mm); sn = 16'(nn); sk = 16'(kk); sfmt = 3'(ff);
    s_first = first; s_last = last; s_valid = 1;
    tick(); @(negedge clk); s_valid = 0;
    // Poison the unowned input bus immediately: the accepted record must survive.
    sm = 3; sn = 5; sk = 7; sfmt = 2;
    cycles = 0;
    while (!s_work && cycles < 80) begin tick(); cycles++; end
    assert (s_work) else $fatal(1, "steer publication timeout");
    expected = policy_topology(s_code, 3'(ff),16'(mm),16'(nn),16'(kk),2'd1,128,2,32'h67788098);
    assert (published_fmt == 3'(ff) && s_topology == expected)
      else $fatal(1, "unaligned publication fmt=%0d/%0d topo=%h/%h",published_fmt,ff,s_topology,expected);
    assert (s_policy == policy_decode(s_code) && next_policy == policy_decode(next_code))
      else $fatal(1, "unaligned policy word");
    if (first) assert (s_commit && s_eval && !s_hold) else $fatal(1,"new batch not committed");
    publication_checks++;
  endtask
  // At the actual consumer edge, baseline and metadata must describe the publication.
  always @(posedge clk) if (rst && s_work && !s_flush && !s_valid) begin
    assert (i_steer.gen_steering.i_subcode.start_i);
    assert (i_steer.gen_steering.i_subcode.baseline_i ==
        policy_topology(s_code, published_fmt,
          i_steer.gen_steering.published_m_q, i_steer.gen_steering.published_n_q,
          i_steer.gen_steering.published_k_q,2'd1,128,2,32'h67788098))
      else $fatal(1,"subcode consumed stale baseline");
  end
  initial begin
    repeat (3) tick(); @(negedge clk); rst = 1;
    for (int f = 0; f < 8; f++) begin
      topology_job(8,16,1,f,1);
      topology_job(32,64,65535,f,1);
      topology_job(8,1,129,f,1); // service-threshold minimum shape
      topology_job(0,64,16,f,1);
      topology_job(16,16,32,f,0);
    end
    for (int j = 0; j < 192; j++)
      topology_job($urandom_range(0,1024),$urandom_range(0,1024),
                   $urandom_range(0,65535),$urandom_range(0,7),$urandom_range(0,3));
    // Kill tokens at every tree stage and within the generic service window.
    for (int delay_cycles = 0; delay_cycles < 20; delay_cycles++) begin
      @(negedge clk); m=8; n=1; k=129; fmt=0; balance=1; valid=1;
      tick(); @(negedge clk); valid=0;
      repeat (delay_cycles) tick();
      @(negedge clk); flush=1; tick(); @(negedge clk); flush=0;
      repeat (25) begin tick(); assert (topo_valid == 0) else $fatal(1,"stale topology after flush"); end
      flush_checks++;
    end
    for (int f = 0; f < 8; f++) begin
      steer_job(64,128,256,f,1,1);
      tick(); assert (!s_work) else $fatal(1,"work pulse repeated");
    end
    s_next_valid = 1; s_next_addr = 64'hfedc_1234_5678_9000;
    steer_job(64,64,32,0,1,0);
    assert (s_warm && s_warm_addr == s_next_addr) else $fatal(1,"warm address truncated");
    s_next_valid = 0;
    // Ordered history must survive the idle cycles used to wait for topology.
    steer_job(16,128,32,0,1,0);
    assert (s_code == POLICY_WIDE) else $fatal(1,"wide seed");
    for (int j = 1; j <= 4; j++) begin
      steer_job(128,16,32,0,0,0);
      assert (s_code == (j < 4 ? POLICY_WIDE : POLICY_TALL))
        else $fatal(1,"hysteresis history lost j=%0d code=%0d",j,s_code);
    end
    // Flush and disable while codec/topology are pending, then accept immediately.
    for (int delay_cycles = 0; delay_cycles < 9; delay_cycles++) begin
      @(negedge clk);
      while (!s_ready) begin tick(); @(negedge clk); end
      s_valid=1; sm=64; sn=64; sk=128; sfmt=0; s_first=1; s_last=1;
      tick(); @(negedge clk); s_valid=0;
      repeat (delay_cycles) tick();
      @(negedge clk);
      if (delay_cycles[0]) s_enable=0; else s_flush=1;
      tick(); @(negedge clk); s_enable=1; s_flush=0;
      repeat (15) begin tick(); assert (!s_work) else $fatal(1,"stale work after cancel"); end
      steer_job(16,64,32,1,1,1);
      flush_checks++;
    end
    // Completion before, after and simultaneous with the result.
    for (int order = 0; order < 3; order++) begin
      @(negedge clk); p_start=1; tick(); @(negedge clk); p_start=0;
      p_data=32'(100+order);
      p_done=order!=1; p_valid=order!=0;
      tick(); @(negedge clk); p_done=0; p_valid=0;
      if (order != 2) begin
        repeat (2) tick();
        assert (!p_ready) else $fatal(1,"join released owner early");
        @(negedge clk); p_done=order==1; p_valid=order==0;
        tick(); @(negedge clk); p_done=0; p_valid=0;
      end
      assert (p_ready && p_snapshot == 32'(100+order)) else $fatal(1,"PMU join ordering");
    end
    @(negedge clk); p_start=1; tick(); @(negedge clk); p_start=0; p_cancel=1;
    tick(); @(negedge clk); p_cancel=0; tick();
    assert (p_ready && p_snapshot == 0) else $fatal(1,"PMU cancel");
    $display("PASS policy_pipeline topology=%0d publications=%0d cancels=%0d pmu_orders=3",
             topology_checks,publication_checks,flush_checks);
    $finish;
  end
  initial begin #2000000; $fatal(1,"policy pipeline timeout"); end
endmodule
`endif

`ifdef G6LC_HYP8_SUBCODE_RESULT_TEST
// Completed evaluator results, independently calculated from matrix byte/service
// counts. Exercise cache-off/cache-on at both generous and tight read bandwidth.
module tb_g6lc_ai_policy_subcode_results;
  import g6lc_ai_policy_pkg::*;
  localparam logic [31:0] Steps = 32'h12311211;
  localparam logic [31:0] MinDepth = 32'h12320100;
  localparam logic [23:0] Shapes = 24'h4420ca;
  logic clk = 0;
  always #5 clk = !clk;
  logic rst = 0, enable = 1, flush = 0, cancel = 0, start = 0;
  logic [15:0] m = 0, n = 0, k = 0;
  logic [2:0] fmt = 0;
  policy_code_t code = POLICY_BULK;
  policy_topology_t baseline;
  logic [3:0] ready, busy, valid, evaluated, hit;
  logic [2:0] subcode [4];
  policy_topology_t topology [4];
  logic [31:0] base_cycles [4], selected_cycles [4];
  int checks = 0, winners = 0, fallbacks = 0, hits = 0, aborts = 0;
  int cold_cycles = 0;
  for (genvar p = 0; p < 4; p++) begin : gen_profile
    g6lc_ai_policy_subcode #(
      .Enabled(1'b1), .CacheEn(p % 2 == 1),
      .ReadBytesPerCycle(p < 2 ? 128 : 1),
      .FormatStepCycles(Steps), .FormatMinReductionLog2(MinDepth),
      .GroupShapeLog2(Shapes)
    ) i_dut (
      .clk_i(clk), .rst_ni(rst), .testmode_i(1'b0), .enable_i(enable),
      .flush_i(flush), .cancel_i(cancel), .start_i(start), .code_i(code),
      .numfmt_i(fmt), .m_i(m), .n_i(n), .k_i(k), .baseline_i(baseline),
      .ready_o(ready[p]), .busy_o(busy[p]), .valid_o(valid[p]),
      .evaluated_o(evaluated[p]), .cache_hit_o(hit[p]),
      .subcode_o(subcode[p]), .topology_o(topology[p]),
      .baseline_cycles_o(base_cycles[p]), .selected_cycles_o(selected_cycles[p])
    );
  end
  task automatic tick;
    @(posedge clk); #1;
  endtask
  function automatic policy_topology_t make_base(input int slots, ff);
    policy_topology_t b;
    b = '0;
    b.valid = 1;
    b.slots_log2 = 4'(slots);
    b.reduction_log2 = 4'(slots);
    b.element_bits_log2 = policy_element_bits_log2(3'(ff));
    return b;
  endfunction
  function automatic longint unsigned rowbytes(input int count, ff);
    case (ff)
      int'(config_pkg::AI_FMT_INT4): return (64'(count) + 1) / 2;
      int'(config_pkg::AI_FMT_FP16), int'(config_pkg::AI_FMT_BF16): return 64'(count) * 2;
      int'(config_pkg::AI_FMT_FP32): return 64'(count) * 4;
      default: return 64'(count);
    endcase
  endfunction
  function automatic longint unsigned cost(
      input int mm, nn, kk, ff, slots, rr, cc, read_bytes);
    int depth, tail;
    longint unsigned inputs, full_service, tail_service, step, service, groups;
    depth = 1 << (slots - rr - cc);
    tail = kk % depth;
    inputs = (64'd1 << rr) + (64'd1 << cc);
    step = 64'(Steps[ff*4 +: 4]);
    full_service = (inputs * rowbytes(depth, ff) + 64'(read_bytes) - 1) / 64'(read_bytes);
    if (full_service < step) full_service = step;
    tail_service = (inputs * rowbytes(tail, ff) + 64'(read_bytes) - 1) / 64'(read_bytes);
    if (tail_service < step) tail_service = step;
    if (tail == 0) tail_service = 0;
    groups = ((64'(mm) >> rr) * (64'(nn) >> cc)) & 64'h1ffff;
    service = ((64'(kk) / 64'(depth)) * full_service + tail_service) & 64'h7fff;
    return (groups * service) & 64'hfffffff;
  endfunction
  task automatic launch(input int mm, nn, kk, ff, slots, input policy_code_t cd);
    int wait_cycles;
    @(negedge clk);
    wait_cycles = 0;
    while (ready != 4'hf && wait_cycles < 10) begin
      tick(); @(negedge clk); wait_cycles++;
    end
    assert (ready == 4'hf) else $fatal(1, "subcode admission");
    m = 16'(mm); n = 16'(nn); k = 16'(kk); fmt = 3'(ff);
    code = cd; baseline = make_base(slots, ff); start = 1;
    tick(); @(negedge clk); start = 0;
    // None of these unowned inputs may alter an evaluation already accepted.
    m = 3; n = 5; k = 7; fmt = 3'(config_pkg::AI_FMT_SP24);
    code = POLICY_WIDE; baseline = '0;
  endtask
  task automatic job(input int mm, nn, kk, ff, slots,
      input policy_code_t cd, input bit cached);
    bit eligible, want_hit;
    int latency [4];
    int best_index, rr, cc, group_index, read_bytes;
    logic [3:0] seen;
    policy_topology_t expected;
    longint unsigned base, best, candidate, chosen, selected;
    eligible = mm > 0 && nn > 0 && kk > 0 && mm <= 256 && nn <= 256 &&
        kk <= 256 && ff != int'(config_pkg::AI_FMT_SP24) &&
        (cd inside {POLICY_BULK, POLICY_DECODE, POLICY_ROUTED, POLICY_SPARSE});
    launch(mm, nn, kk, ff, slots, cd);
    seen = '0;
    for (int cycle = 0; cycle < 1200 && seen != 4'hf; cycle++) begin
      for (int p = 0; p < 4; p++) if (valid[p] && !seen[p]) begin
        seen[p] = 1;
        latency[p] = cycle;
      end
      if (seen != 4'hf) tick();
    end
    assert (seen == 4'hf) else $fatal(1, "subcode completion timeout");
    case (cd)
      POLICY_DECODE: group_index = 1;
      POLICY_ROUTED: group_index = 2;
      POLICY_SPARSE: group_index = 3;
      default: group_index = 0;
    endcase
    for (int p = 0; p < 4; p++) begin
      expected = make_base(slots, ff);
      base = 0; best = 0; chosen = 0; selected = 0; best_index = 0;
      want_hit = eligible && cached && (p % 2 == 1);
      read_bytes = p < 2 ? 128 : 1;
      if (eligible) begin
        base = cost(mm, nn, kk, ff, slots, 0, 0, read_bytes);
        best = base;
        for (int index = 1; index < 8; index++) begin
          rr = 0; cc = 0;
          case (index)
            2: cc = 4;
            3: begin rr = 1; cc = 3; end
            4: begin rr = 2; cc = 2; end
            5: begin rr = 3; cc = 1; end
            6: rr = 4;
            7: begin
              rr = int'(Shapes[group_index*6+3 +: 3]);
              cc = int'(Shapes[group_index*6 +: 3]);
            end
            default: begin end
          endcase
          if (rr + cc <= slots && (mm % (1 << rr)) == 0 && (nn % (1 << cc)) == 0 &&
              slots - rr - cc >= int'(MinDepth[ff*4 +: 4])) begin
            candidate = cost(mm, nn, kk, ff, slots, rr, cc, read_bytes);
            if (candidate < best) begin
              best = candidate; best_index = index;
              expected.rows_log2 = 3'(rr); expected.cols_log2 = 3'(cc);
              expected.reduction_log2 = 4'(slots - rr - cc);
              expected.apply = rr != 0 || cc != 0;
              expected.gain_16ths = 4'(((2 * (1 << (rr + cc)) -
                  (1 << rr) - (1 << cc)) * 16) / (2 * (1 << (rr + cc))));
            end
          end
        end
        if (best_index != 0 && best + 2 + 32 + 2 < base) chosen = best;
        else begin best_index = 0; chosen = base; expected = make_base(slots, ff); end
        selected = chosen + (best_index != 0 ? 64'd2 : 64'd0) + (want_hit ? 64'd1 : 64'd32);
        if (best_index != 0) winners++; else fallbacks++;
        if (!want_hit) cold_cycles = latency[p];
        if (want_hit) begin
          assert (latency[p] == 1) else $fatal(1, "subcode cache latency");
          hits++;
        end
      end
      if ($test$plusargs("negative_subcode_oracle") && eligible && p == 0) selected ^= 1;
      assert (evaluated[p] == eligible && hit[p] == want_hit &&
          subcode[p] == 3'(best_index) && topology[p] == expected &&
          base_cycles[p] == 32'(base) && selected_cycles[p] == 32'(selected))
        else $fatal(1, "subcode result p=%0d m/n/k=%0d/%0d/%0d fmt=%0d code=%0d/%0d base=%0d/%0d selected=%0d/%0d",
                    p,mm,nn,kk,ff,subcode[p],best_index,base_cycles[p],base,selected_cycles[p],selected);
      checks++;
    end
  endtask
  initial begin
    baseline = '0;
    repeat (3) tick(); @(negedge clk); rst = 1;
    tick();
    for (int ff = 0; ff < 8; ff++) begin
      for (int g = 0; g < 4; g++) begin
        policy_code_t cd;
        case (g)
          1: cd = POLICY_DECODE;
          2: cd = POLICY_ROUTED;
          3: cd = POLICY_SPARSE;
          default: cd = POLICY_BULK;
        endcase
        job(g == 0 ? 1 : 32 << (g-1), g == 0 ? 1 : 128 >> (g-1),
            255 - g, ff, 3 + g, cd, 0);
        job(g == 0 ? 1 : 32 << (g-1), g == 0 ? 1 : 128 >> (g-1),
            255 - g, ff, 3 + g, cd, 1);
      end
    end
    job(256,256,256,int'(config_pkg::AI_FMT_FP32),9,POLICY_BULK,0);
    job(16,24,17,int'(config_pkg::AI_FMT_INT4),2,POLICY_ROUTED,0);
    job(0,64,64,0,6,POLICY_BULK,0);
    job(257,64,64,0,6,POLICY_BULK,0);
    job(64,64,64,0,6,POLICY_WIDE,0);
    // Abort at shape/prep, multiplier and late-evaluation boundaries.
    for (int a = 0; a < 6; a++) begin
      int delay_cycles;
      case (a)
        0: delay_cycles = 0;
        1: delay_cycles = 1;
        2: delay_cycles = 2;
        3: delay_cycles = 35;
        4: delay_cycles = 100;
        default: delay_cycles = 810;
      endcase
      @(negedge clk); flush = 1; tick(); @(negedge clk); flush = 0; tick();
      launch(64,128,255,int'(config_pkg::AI_FMT_FP32),6,POLICY_BULK);
      repeat (delay_cycles) tick();
      assert (valid == 0) else $fatal(1, "abort must precede completion");
      @(negedge clk);
      if (a % 3 == 0) cancel = 1;
      else if (a % 3 == 1) flush = 1;
      else enable = 0;
      tick(); @(negedge clk); cancel = 0; flush = 0; enable = 1;
      repeat (3) begin tick(); assert (valid == 0) else $fatal(1, "subcode stale result after abort"); end
      job(32,16,17,0,5,POLICY_ROUTED,0);
      aborts++;
    end
    assert (checks > 0 && winners > 0 && fallbacks > 0 && hits > 0 && aborts == 6);
    $display("PASS subcode_results checks=%0d winners=%0d fallback=%0d cache_hits=%0d aborts=%0d cold_cycles=%0d",
             checks,winners,fallbacks,hits,aborts,cold_cycles);
    $finish;
  end
  initial begin #2000000; $fatal(1, "subcode result timeout"); end
endmodule
`endif
