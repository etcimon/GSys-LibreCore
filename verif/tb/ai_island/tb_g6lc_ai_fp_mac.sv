// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Etienne Cimon

module tb_g6lc_ai_fp_mac #(
  parameter int unsigned FpPipeRegs = 3
) (
  input logic clk_i,
  input logic rst_ni,
  input logic testmode_i,
  input logic enable_i,
  input logic flush_i,
  input logic req_valid_i,
  output logic req_ready_o,
  input logic [2:0] numfmt_i,
  input logic [31:0] a_i,
  input logic [31:0] b_i,
  input logic [31:0] acc_i,
  output logic result_valid_o,
  input logic result_ready_i,
  output logic [31:0] result_o,
  output logic [4:0] flags_o,
  output logic error_o,
  output logic busy_o,
  input logic [31:0] probe_raw_i,
  input logic [2:0] probe_fmt_i,
  output logic [31:0] probe_value_o,
  output logic probe_snan_o,
  output logic probe_valid_o,
  output logic [40:0] disabled_o
);
  function automatic config_pkg::ai_cfg_t make_cfg();
    config_pkg::ai_cfg_t cfg = config_pkg::AiCfgOff;
    cfg.MatrixEn = 1'b1;
    cfg.IslandFpEn = 1'b1;
    cfg.Queues = 1;
    return cfg;
  endfunction
  localparam config_pkg::ai_cfg_t TestCfg = make_cfg();
  g6lc_ai_fp_pkg::fp_widen_t widened;
  assign widened = g6lc_ai_fp_pkg::fp_widen(probe_raw_i, probe_fmt_i);
  assign probe_value_o = widened.value;
  assign probe_snan_o = widened.snan;
  assign probe_valid_o = widened.valid;

  g6lc_ai_fp_mac #(.AiCfg(TestCfg), .FpPipeRegs(FpPipeRegs)) i_mac (.*);
  g6lc_ai_fp_mac i_disabled (
    .clk_i(clk_i), .rst_ni(rst_ni), .testmode_i(testmode_i),
    .enable_i(enable_i), .flush_i(flush_i), .req_valid_i(req_valid_i),
    .req_ready_o(disabled_o[0]), .numfmt_i(numfmt_i), .a_i(a_i), .b_i(b_i), .acc_i(acc_i),
    .result_valid_o(disabled_o[1]), .result_ready_i(result_ready_i),
    .result_o(disabled_o[33:2]), .flags_o(disabled_o[38:34]),
    .error_o(disabled_o[39]), .busy_o(disabled_o[40])
  );

`ifdef FORMAL
  logic past_valid = 1'b0;
  always_ff @(posedge clk_i) begin
    past_valid <= 1'b1;
    if (!past_valid) assume (!rst_ni);
    assert (disabled_o == 0);
    assert (!(req_ready_o && busy_o));
    assert (!result_valid_o || busy_o);
    if (!rst_ni || !enable_i || flush_i)
      assert (!req_ready_o && !result_valid_o && !busy_o);
    if (past_valid && rst_ni && $past(rst_ni)) begin
      if (enable_i && !flush_i && $past(enable_i && !flush_i && result_valid_o && !result_ready_i)) begin
        assert (result_valid_o);
        assert ({result_o, flags_o, error_o} == $past({result_o, flags_o, error_o}));
      end
      if ($past(flush_i || !enable_i)) assert (!result_valid_o);
      if (enable_i && !flush_i && $past(req_valid_i && req_ready_o && numfmt_i < 3)) begin
        assert (result_valid_o && error_o && result_o == 0 && flags_o == 0);
      end
    end
  end
`endif
endmodule

module tb_g6lc_ai_fp_widen_formal (
  input logic [31:0] raw_i,
  output logic [31:0] fp32_o,
  output logic [31:0] bf16_o
);
  g6lc_ai_fp_pkg::fp_widen_t fp32, bf16, fp16, e4m3, e5m2, unsupported;
  assign fp32 = g6lc_ai_fp_pkg::fp_widen(raw_i, 3'd7);
  assign bf16 = g6lc_ai_fp_pkg::fp_widen(raw_i, 3'd6);
  assign fp16 = g6lc_ai_fp_pkg::fp_widen(raw_i, 3'd5);
  assign e5m2 = g6lc_ai_fp_pkg::fp_widen(raw_i, 3'd4);
  assign e4m3 = g6lc_ai_fp_pkg::fp_widen(raw_i, 3'd3);
  assign unsupported = g6lc_ai_fp_pkg::fp_widen(raw_i, 3'd2);
  assign fp32_o = fp32.value;
  assign bf16_o = bf16.value;
`ifdef FORMAL
  always_comb begin
    assert (fp32.value == raw_i && fp32.valid && !fp32.snan);
    assert (bf16.value == {raw_i[15:0], 16'd0} && bf16.valid && !bf16.snan);
    assert (unsupported == 0);
    assert (fp16.valid && e5m2.valid && e4m3.valid && !e4m3.snan);
    if (raw_i[14:0] == 0) assert (fp16.value == {raw_i[15], 31'd0});
    if (raw_i[6:0] == 0) begin
      assert (e4m3.value == {raw_i[7], 31'd0});
      assert (e5m2.value == {raw_i[7], 31'd0});
    end
    if (raw_i[14:10] == 5'h1f && raw_i[9:0] != 0) begin
      assert (fp16.value == 32'h7fc00000);
      assert (fp16.snan == !raw_i[9]);
    end
    if (raw_i[6:2] == 5'h1f && raw_i[1:0] != 0) begin
      assert (e5m2.value == 32'h7fc00000);
      assert (e5m2.snan == !raw_i[1]);
    end
    if (raw_i[6:0] == 7'h7f) assert (e4m3.value == 32'h7fc00000);
    if (raw_i[6:0] == 7'h7e) assert (e4m3.value == {raw_i[7], 31'h43e00000});
    if (raw_i[14:10] == 0 && raw_i[9:0] != 0) begin
      assert (fp16.value[30:23] != 0 && fp16.value[30:23] != 8'hff);
      assert (fp16.value[31] == raw_i[15]);
    end
    if (raw_i[6:3] == 0 && raw_i[2:0] != 0) begin
      assert (e4m3.value[30:23] != 0 && e4m3.value[30:23] != 8'hff);
      assert (e4m3.value[31] == raw_i[7]);
    end
  end
`endif
endmodule
