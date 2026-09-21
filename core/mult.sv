

module mult
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type fu_data_t = logic
) (
    // Subsystem Clock - SUBSYSTEM
    input  logic                                 clk_i,
    // Asynchronous reset active low - SUBSYSTEM
    input  logic                                 rst_ni,
    // Flush - CONTROLLER
    input  logic                                 flush_i,
    input  logic [CVA6Cfg.NR_SB_ENTRIES-1:0]     cancelled_mask_i,
    // FU data needed to execute instruction - ISSUE_STAGE
    input  fu_data_t                             fu_data_i,
    // Mult instruction is valid - ISSUE_STAGE
    input  logic                                 mult_valid_i,
    // Mult result - ISSUE_STAGE
    output logic     [         CVA6Cfg.XLEN-1:0] result_o,
    // Mult result is valid - ISSUE_STAGE
    output logic                                 mult_valid_o,
    // Mutl is ready - ISSUE_STAGE
    output logic                                 mult_ready_o,
    // Mult transaction ID - ISSUE_STAGE
    output logic     [CVA6Cfg.TRANS_ID_BITS-1:0] mult_trans_id_o
);
  logic mul_valid;
  logic div_valid;
  logic div_ready_i;  // receiver of division result is able to accept the result
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] mul_trans_id;
  logic [CVA6Cfg.TRANS_ID_BITS-1:0] div_trans_id;
  logic [CVA6Cfg.XLEN-1:0] mul_result;
  logic [CVA6Cfg.XLEN-1:0] div_result;

  logic div_valid_op;
  logic mul_valid_op;
  logic div_owner_free, div_in_fire, div_out_fire, div_result_live, div_valid_raw;
  logic [CVA6Cfg.NR_SB_ENTRIES-1:0] div_owner_live_q, div_owner_cancelled_q;
  logic div_idle_q;
  // Input Arbitration

  assign mul_valid_op = ~flush_i && mult_valid_i && (fu_data_i.operation inside { MUL, MULH, MULHU, MULHSU, MULW, CLMUL, CLMULH, CLMULR });

  assign div_owner_free = !CVA6Cfg.OoOEn || (!div_owner_live_q[fu_data_i.trans_id] && !cancelled_mask_i[fu_data_i.trans_id]);
  assign div_valid_op = ~flush_i && mult_valid_i && div_owner_free && (fu_data_i.operation inside { DIV, DIVU, DIVW, DIVUW, REM, REMU, REMW, REMUW });

  // ---------------------
  // Output Arbitration
  // ---------------------
  // we give precedence to multiplication as the divider supports stalling and the multiplier is
  // just a dumb pipelined multiplier
  assign div_ready_i = (mul_valid) ? 1'b0 : 1'b1;
  assign mult_trans_id_o = (mul_valid) ? mul_trans_id : div_trans_id;
  assign result_o = (mul_valid) ? mul_result : div_result;
  assign div_result_live = !CVA6Cfg.OoOEn ||
      (!flush_i && div_owner_live_q[div_trans_id] && !div_owner_cancelled_q[div_trans_id] &&
       !cancelled_mask_i[div_trans_id]);
  assign div_valid = div_valid_raw && div_result_live;
  assign div_in_fire = div_valid_op && div_idle_q;
  assign div_out_fire = div_valid_raw && div_ready_i;
  assign mult_valid_o = div_valid | mul_valid;
  if (CVA6Cfg.OoOEn) begin : gen_div_owner_lifetime
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) begin
        div_owner_live_q <= '0;
        div_owner_cancelled_q <= '0;
      end else if (flush_i) begin
        div_owner_live_q <= '0;
        div_owner_cancelled_q <= '0;
      end else begin
        div_owner_cancelled_q <= (div_owner_cancelled_q | cancelled_mask_i) & div_owner_live_q;
        if (div_out_fire) begin
          div_owner_live_q[div_trans_id] <= 1'b0;
          div_owner_cancelled_q[div_trans_id] <= 1'b0;
        end
        if (div_in_fire) begin
          div_owner_live_q[fu_data_i.trans_id] <= 1'b1;
          div_owner_cancelled_q[fu_data_i.trans_id] <= 1'b0;
        end
      end
    end
    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (~rst_ni) div_idle_q <= 1'b1;
      else if (flush_i) div_idle_q <= 1'b1;
      else if (div_out_fire) div_idle_q <= 1'b1;
      else if (div_in_fire) div_idle_q <= 1'b0;
    end
  end else begin : gen_no_div_owner_lifetime
    assign div_owner_live_q = '0;
    assign div_owner_cancelled_q = '0;
    assign div_idle_q = 1'b1;
  end
  // mult_ready_o = division as the multiplication will unconditionally be ready to accept new requests

  // ---------------------
  // Multiplication
  // ---------------------
  multiplier #(
      .CVA6Cfg(CVA6Cfg)
  ) i_multiplier (
      .clk_i,
      .rst_ni,
      .trans_id_i     (fu_data_i.trans_id),
      .operation_i    (fu_data_i.operation),
      .operand_a_i    (fu_data_i.operand_a),
      .operand_b_i    (fu_data_i.operand_b),
      .result_o       (mul_result),
      .mult_valid_i   (mul_valid_op),
      .mult_valid_o   (mul_valid),
      .mult_trans_id_o(mul_trans_id)
  );

  // ---------------------
  // Division
  // ---------------------
  logic [CVA6Cfg.XLEN-1:0]
      operand_b,
      operand_a;  // input operands after input MUX (input silencing, word operations or full inputs)
  logic [CVA6Cfg.XLEN-1:0] result;  // result before result mux

  logic                    div_signed;  // signed or unsigned division
  logic                    rem;  // is it a reminder (or not a reminder e.g.: a division)
  logic word_op_d, word_op_q;  // save whether the operation was signed or not

  // is this a signed op?
  assign div_signed = fu_data_i.operation inside {DIV, DIVW, REM, REMW};
  // is this a modulo?
  assign rem        = fu_data_i.operation inside {REM, REMU, REMW, REMUW};

  // prepare the input operands and control divider
  always_comb begin
    // silence the inputs
    operand_a = '0;
    operand_b = '0;
    // control signals
    word_op_d = word_op_q;

    // we've go a new division operation
    if (mult_valid_i && fu_data_i.operation inside {DIV, DIVU, DIVW, DIVUW, REM, REMU, REMW, REMUW}) begin
      // is this a word operation?
      if (CVA6Cfg.IS_XLEN64 && (fu_data_i.operation == DIVW || fu_data_i.operation == DIVUW || fu_data_i.operation == REMW || fu_data_i.operation == REMUW)) begin
        // yes so check if we should sign extend this is only done for a signed operation
        if (div_signed) begin
          operand_a = sext32to64(fu_data_i.operand_a[31:0]);
          operand_b = sext32to64(fu_data_i.operand_b[31:0]);
        end else begin
          operand_a = CVA6Cfg.XLEN'(fu_data_i.operand_a[31:0]);
          operand_b = CVA6Cfg.XLEN'(fu_data_i.operand_b[31:0]);
        end

        // save whether we want sign extend the result or not, this is done for all word operations
        word_op_d = 1'b1;
      end else begin
        // regular op
        operand_a = fu_data_i.operand_a;
        operand_b = fu_data_i.operand_b;
        word_op_d = 1'b0;
      end
    end
  end

  // ---------------------
  // Serial Divider
  // ---------------------
  serdiv #(
      .CVA6Cfg(CVA6Cfg),
      .WIDTH  (CVA6Cfg.XLEN)
  ) i_div (
      .clk_i    (clk_i),
      .rst_ni   (rst_ni),
      .id_i     (fu_data_i.trans_id),
      .op_a_i   (operand_a),
      .op_b_i   (operand_b),
      .opcode_i ({rem, div_signed}),   // 00: udiv, 10: urem, 01: div, 11: rem
      .in_vld_i (div_valid_op),
      .in_rdy_o (mult_ready_o),
      .flush_i  (flush_i),
      .out_vld_o(div_valid_raw),
      .out_rdy_i(div_ready_i),
      .id_o     (div_trans_id),
      .res_o    (result)
  );

  // Result multiplexer
  // if it was a signed word operation the bit will be set and the result will be sign extended accordingly
  assign div_result = (CVA6Cfg.IS_XLEN64 && word_op_q) ? sext32to64(result[31:0]) : result;

  // ---------------------
  // Registers
  // ---------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      word_op_q <= '0;
    end else begin
      word_op_q <= word_op_d;
    end
  end
endmodule
