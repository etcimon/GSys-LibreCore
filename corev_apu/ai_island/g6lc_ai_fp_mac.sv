// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

module g6lc_ai_fp_mac #(
  parameter config_pkg::ai_cfg_t AiCfg = config_pkg::AiCfgOff,
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
  output logic busy_o
);
  if (AiCfg.IslandFpEn && AiCfg.MatrixEn && AiCfg.Queues > 0) begin : gen_enabled
    typedef enum logic [2:0] {
      IDLE, MUL_ISSUE, MUL_WAIT, ADD_ISSUE, ADD_WAIT, RESPONSE
    } state_t;
    state_t state_q, state_d;
    logic [31:0] a_q, a_d, b_q, b_d, acc_q, acc_d;
    logic [31:0] product_q, product_d, result_q, result_d;
    logic [2:0] numfmt_q, numfmt_d;
    logic [4:0] flags_q, flags_d;
    logic error_q, error_d;
    logic active, accept_req, control_enable;
    g6lc_ai_fp_pkg::fp_widen_t widened_a, widened_b;
    logic [2:0][31:0] fp_operands;
    fpnew_pkg::operation_e fp_op;
    logic fp_in_valid, fp_in_ready, fp_out_valid, fp_out_ready;
    logic [31:0] fp_result;
    fpnew_pkg::status_t fp_status;

    assign active = rst_ni && enable_i && !flush_i;
    assign req_ready_o = active && state_q == IDLE;
    assign accept_req = req_valid_i && req_ready_o;
    assign result_valid_o = active && state_q == RESPONSE;
    assign result_o = result_q;
    assign flags_o = flags_q;
    assign error_o = error_q;
    assign busy_o = active && state_q != IDLE;
    assign control_enable = testmode_i || accept_req || state_q != IDLE;
    assign widened_a = g6lc_ai_fp_pkg::fp_widen(a_q, numfmt_q);
    assign widened_b = g6lc_ai_fp_pkg::fp_widen(b_q, numfmt_q);
    assign fp_in_valid = active && (state_q == MUL_ISSUE || state_q == ADD_ISSUE);
    assign fp_out_ready = active && (state_q == MUL_WAIT || state_q == ADD_WAIT);
    assign fp_op = state_q == ADD_ISSUE ? fpnew_pkg::ADD : fpnew_pkg::MUL;
    assign fp_operands[0] = widened_a.value;
    assign fp_operands[1] = state_q == ADD_ISSUE ? product_q : widened_b.value;
    assign fp_operands[2] = acc_q;

    fpnew_fma #(
      .FpFormat(fpnew_pkg::FP32),
      .NumPipeRegs(FpPipeRegs),
      .PipeConfig(fpnew_pkg::DISTRIBUTED),
      .TagType(logic),
      .AuxType(logic)
    ) i_fp32 (
      .clk_i(clk_i), .rst_ni(rst_ni),
      .operands_i(fp_operands), .is_boxed_i(3'b111),
      .rnd_mode_i(fpnew_pkg::RNE), .op_i(fp_op), .op_mod_i(1'b0),
      .tag_i(1'b0), .mask_i(1'b1), .aux_i(1'b0),
      .in_valid_i(fp_in_valid), .in_ready_o(fp_in_ready),
      .flush_i(flush_i || !enable_i),
      .result_o(fp_result), .status_o(fp_status),
      .extension_bit_o(), .tag_o(), .mask_o(), .aux_o(),
      .out_valid_o(fp_out_valid), .out_ready_i(fp_out_ready),
      .busy_o(), .reg_ena_i('0), .early_out_valid_o()
    );

    always_comb begin
      state_d = state_q;
      a_d = a_q;
      b_d = b_q;
      acc_d = acc_q;
      numfmt_d = numfmt_q;
      product_d = product_q;
      result_d = result_q;
      flags_d = flags_q;
      error_d = error_q;
      case (state_q)
        IDLE: if (accept_req) begin
          a_d = a_i;
          b_d = b_i;
          acc_d = acc_i;
          numfmt_d = numfmt_i;
          product_d = '0;
          result_d = '0;
          flags_d = '0;
          error_d = numfmt_i < 3'(config_pkg::AI_FMT_FP8_E4M3);
          state_d = error_d ? RESPONSE : MUL_ISSUE;
        end
        MUL_ISSUE: if (fp_in_valid && fp_in_ready) begin
          flags_d = {widened_a.snan || widened_b.snan, 4'd0};
          state_d = MUL_WAIT;
        end
        MUL_WAIT: if (fp_out_valid && fp_out_ready) begin
          product_d = fp_result;
          flags_d = flags_q | fp_status;
          state_d = ADD_ISSUE;
        end
        ADD_ISSUE: if (fp_in_valid && fp_in_ready) state_d = ADD_WAIT;
        ADD_WAIT: if (fp_out_valid && fp_out_ready) begin
          result_d = fp_result;
          flags_d = flags_q | fp_status;
          state_d = RESPONSE;
        end
        RESPONSE: if (result_valid_o && result_ready_i) state_d = IDLE;
        default: state_d = IDLE;
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q <= IDLE;
        a_q <= '0;
        b_q <= '0;
        acc_q <= '0;
        numfmt_q <= '0;
        product_q <= '0;
        result_q <= '0;
        flags_q <= '0;
        error_q <= 1'b0;
      end else if (flush_i || !enable_i) begin
        state_q <= IDLE;
        a_q <= '0;
        b_q <= '0;
        acc_q <= '0;
        numfmt_q <= '0;
        product_q <= '0;
        result_q <= '0;
        flags_q <= '0;
        error_q <= 1'b0;
      end else if (control_enable) begin
        state_q <= state_d;
        a_q <= a_d;
        b_q <= b_d;
        acc_q <= acc_d;
        numfmt_q <= numfmt_d;
        product_q <= product_d;
        result_q <= result_d;
        flags_q <= flags_d;
        error_q <= error_d;
      end
    end

    //pragma translate_off
    initial assert (FpPipeRegs >= 1) else $fatal(1, "FP MAC requires at least one pipeline register");
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      result_valid_o && !result_ready_i |=> !enable_i || flush_i ||
      (result_valid_o && $stable({result_o, flags_o, error_o})));
    assert property (@(posedge clk_i) disable iff (!rst_ni)
      fp_in_valid |-> (state_q == MUL_ISSUE || state_q == ADD_ISSUE));
    //pragma translate_on
  end else begin : gen_disabled
    assign req_ready_o = 1'b0;
    assign result_valid_o = 1'b0;
    assign result_o = '0;
    assign flags_o = '0;
    assign error_o = 1'b0;
    assign busy_o = 1'b0;
  end

  //pragma translate_off
  initial assert (!AiCfg.IslandFpEn || (AiCfg.MatrixEn && AiCfg.Queues > 0))
    else $fatal(1, "IslandFpEn requires MatrixEn and descriptor queues");
  //pragma translate_on
endmodule
