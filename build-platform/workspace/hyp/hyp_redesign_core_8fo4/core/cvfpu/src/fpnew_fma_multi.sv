// hyp8 provenance: AS-IS (sv-timing emit at the 8-FO4 budget)
// Copyright 2019 ETH Zurich and University of Bologna.
//
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License. You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// SPDX-License-Identifier: SHL-0.51

// Author: Stefan Mach <smach@iis.ee.ethz.ch>

`include "common_cells/registers.svh"

module fpnew_fma_multi #(
  parameter fpnew_pkg::fmt_logic_t   FpFmtConfig = '1,
  parameter int unsigned             NumPipeRegs = 0,
  parameter fpnew_pkg::pipe_config_t PipeConfig  = fpnew_pkg::BEFORE,
  parameter type                     TagType     = logic,
  parameter type                     AuxType     = logic,
  // Do not change
  localparam int unsigned WIDTH       = fpnew_pkg::max_fp_width(FpFmtConfig),
  localparam int unsigned NUM_FORMATS = fpnew_pkg::NUM_FP_FORMATS,
  localparam int unsigned ExtRegEnaWidth = NumPipeRegs == 0 ? 1 : NumPipeRegs
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  // Input signals
  input  logic [2:0][WIDTH-1:0]       operands_i, // 3 operands
  input  logic [NUM_FORMATS-1:0][2:0] is_boxed_i, // 3 operands
  input  fpnew_pkg::roundmode_e       rnd_mode_i,
  input  fpnew_pkg::operation_e       op_i,
  input  logic                        op_mod_i,
  input  fpnew_pkg::fp_format_e       src_fmt_i,  // format of the multiplicands
  input  fpnew_pkg::fp_format_e       src2_fmt_i, // format of the addend
  input  fpnew_pkg::fp_format_e       dst_fmt_i,  // format of the result
  input  TagType                      tag_i,
  input  logic                        mask_i,
  input  AuxType                      aux_i,
  // Input Handshake
  input  logic                        in_valid_i,
  output logic                        in_ready_o,
  input  logic                        flush_i,
  // Output signals
  output logic [WIDTH-1:0]            result_o,
  output fpnew_pkg::status_t          status_o,
  output logic                        extension_bit_o,
  output TagType                      tag_o,
  output logic                        mask_o,
  output AuxType                      aux_o,
  // Output handshake
  output logic                        out_valid_o,
  input  logic                        out_ready_i,
  // Indication of valid data in flight
  output logic                        busy_o,
  // External register enable override
  input  logic [ExtRegEnaWidth-1:0]   reg_ena_i,
  // Early valid for external structural hazard generation
  output logic                        early_out_valid_o
);

  // ----------
  // Constants
  // ----------
  // The super-format that can hold all formats
  localparam fpnew_pkg::fp_encoding_t SUPER_FORMAT = fpnew_pkg::super_format(FpFmtConfig);

  localparam int unsigned SUPER_EXP_BITS = SUPER_FORMAT.exp_bits;
  localparam int unsigned SUPER_MAN_BITS = SUPER_FORMAT.man_bits;

  // Precision bits 'p' include the implicit bit
  localparam int unsigned PRECISION_BITS = SUPER_MAN_BITS + 1;
  // The lower 2p+3 bits of the internal FMA result will be needed for leading-zero detection
  localparam int unsigned LOWER_SUM_WIDTH  = 2 * PRECISION_BITS + 3;
  localparam int unsigned LZC_RESULT_WIDTH = $clog2(LOWER_SUM_WIDTH);
  // Internal exponent width of FMA must accomodate all meaningful exponent values in order to avoid
  // datapath leakage. This is either given by the exponent bits or the width of the LZC result.
  // In most reasonable FP formats the internal exponent will be wider than the LZC result.
  localparam int unsigned EXP_WIDTH = fpnew_pkg::maximum(SUPER_EXP_BITS + 2, LZC_RESULT_WIDTH);
  // Shift amount width: maximum internal mantissa size is 3p+4 bits
  localparam int unsigned SHIFT_AMOUNT_WIDTH = $clog2(3 * PRECISION_BITS + 5);
  // Pipelines
  localparam NUM_INP_REGS = PipeConfig == fpnew_pkg::BEFORE
                            ? NumPipeRegs
                            : (PipeConfig == fpnew_pkg::DISTRIBUTED
                               ? ((NumPipeRegs + 1) / 3) // Second to get distributed regs
                               : 0); // no regs here otherwise
  localparam NUM_MID_REGS = PipeConfig == fpnew_pkg::INSIDE
                          ? NumPipeRegs
                          : (PipeConfig == fpnew_pkg::DISTRIBUTED
                             ? ((NumPipeRegs + 2) / 3) // First to get distributed regs
                             : 0); // no regs here otherwise
  localparam NUM_OUT_REGS = PipeConfig == fpnew_pkg::AFTER
                            ? NumPipeRegs
                            : (PipeConfig == fpnew_pkg::DISTRIBUTED
                               ? (NumPipeRegs / 3) // Last to get distributed regs
                               : 0); // no regs here otherwise

  // ----------------
  // Type definition
  // ----------------
  typedef struct packed {
    logic                      sign;
    logic [SUPER_EXP_BITS-1:0] exponent;
    logic [SUPER_MAN_BITS-1:0] mantissa;
  } fp_t;

  // ---------------
  // Input pipeline
  // ---------------
  // Selected pipeline output signals as non-arrays
  logic [2:0][WIDTH-1:0] operands_q;
  fpnew_pkg::fp_format_e src_fmt_q;
  fpnew_pkg::fp_format_e src2_fmt_q;
  fpnew_pkg::fp_format_e dst_fmt_q;

  // Input pipeline signals, index i holds signal after i register stages
  logic                  [0:NUM_INP_REGS][2:0][WIDTH-1:0]       inp_pipe_operands_q;
  logic                  [0:NUM_INP_REGS][NUM_FORMATS-1:0][2:0] inp_pipe_is_boxed_q;
  fpnew_pkg::roundmode_e [0:NUM_INP_REGS]                       inp_pipe_rnd_mode_q;
  fpnew_pkg::operation_e [0:NUM_INP_REGS]                       inp_pipe_op_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_op_mod_q;
  fpnew_pkg::fp_format_e [0:NUM_INP_REGS]                       inp_pipe_src_fmt_q;
  fpnew_pkg::fp_format_e [0:NUM_INP_REGS]                       inp_pipe_src2_fmt_q;
  fpnew_pkg::fp_format_e [0:NUM_INP_REGS]                       inp_pipe_dst_fmt_q;
  TagType                [0:NUM_INP_REGS]                       inp_pipe_tag_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_mask_q;
  AuxType                [0:NUM_INP_REGS]                       inp_pipe_aux_q;
  logic                  [0:NUM_INP_REGS]                       inp_pipe_valid_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_INP_REGS] inp_pipe_ready;

  // Input stage: First element of pipeline is taken from inputs
  assign inp_pipe_operands_q[0] = operands_i;
  assign inp_pipe_is_boxed_q[0] = is_boxed_i;
  assign inp_pipe_rnd_mode_q[0] = rnd_mode_i;
  assign inp_pipe_op_q[0]       = op_i;
  assign inp_pipe_op_mod_q[0]   = op_mod_i;
  assign inp_pipe_src_fmt_q[0]  = src_fmt_i;
  assign inp_pipe_src2_fmt_q[0] = src2_fmt_i;
  assign inp_pipe_dst_fmt_q[0]  = dst_fmt_i;
  assign inp_pipe_tag_q[0]      = tag_i;
  assign inp_pipe_mask_q[0]     = mask_i;
  assign inp_pipe_aux_q[0]      = aux_i;
  assign inp_pipe_valid_q[0]    = in_valid_i;
  // Input stage: Propagate pipeline ready signal to updtream circuitry
  assign in_ready_o = inp_pipe_ready[0];
  // Generate the register stages
  for (genvar i = 0; i < NUM_INP_REGS; i++) begin : gen_input_pipeline
    // Internal register enable for this stage
    logic reg_ena;
    // Determine the ready signal of the current stage - advance the pipeline:
    // 1. if the next stage is ready for our data
    // 2. if the next stage only holds a bubble (not valid) -> we can pop it
    assign inp_pipe_ready[i] = inp_pipe_ready[i+1] | ~inp_pipe_valid_q[i+1];
    // Valid: enabled by ready signal, synchronous clear with the flush signal
    `FFLARNC(inp_pipe_valid_q[i+1], inp_pipe_valid_q[i], inp_pipe_ready[i], flush_i, 1'b0, clk_i, rst_ni)
    // Enable register if pipleine ready and a valid data item is present
    assign reg_ena = (inp_pipe_ready[i] & inp_pipe_valid_q[i]) | reg_ena_i[i];
    // Generate the pipeline registers within the stages, use enable-registers
    `FFL(inp_pipe_operands_q[i+1], inp_pipe_operands_q[i], reg_ena, '0)
    `FFL(inp_pipe_is_boxed_q[i+1], inp_pipe_is_boxed_q[i], reg_ena, '0)
    `FFL(inp_pipe_rnd_mode_q[i+1], inp_pipe_rnd_mode_q[i], reg_ena, fpnew_pkg::RNE)
    `FFL(inp_pipe_op_q[i+1],       inp_pipe_op_q[i],       reg_ena, fpnew_pkg::FMADD)
    `FFL(inp_pipe_op_mod_q[i+1],   inp_pipe_op_mod_q[i],   reg_ena, '0)
    `FFL(inp_pipe_src_fmt_q[i+1],  inp_pipe_src_fmt_q[i],  reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(inp_pipe_src2_fmt_q[i+1], inp_pipe_src2_fmt_q[i], reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(inp_pipe_dst_fmt_q[i+1],  inp_pipe_dst_fmt_q[i],  reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(inp_pipe_tag_q[i+1],      inp_pipe_tag_q[i],      reg_ena, TagType'('0))
    `FFL(inp_pipe_mask_q[i+1],     inp_pipe_mask_q[i],     reg_ena, '0)
    `FFL(inp_pipe_aux_q[i+1],      inp_pipe_aux_q[i],      reg_ena, AuxType'('0))
  end
  // Output stage: assign selected pipe outputs to signals for later use
  assign operands_q = inp_pipe_operands_q[NUM_INP_REGS];
  assign src_fmt_q  = inp_pipe_src_fmt_q[NUM_INP_REGS];
  assign src2_fmt_q = inp_pipe_src2_fmt_q[NUM_INP_REGS];
  assign dst_fmt_q  = inp_pipe_dst_fmt_q[NUM_INP_REGS];

  // -----------------
  // Input processing
  // -----------------
  logic        [NUM_FORMATS-1:0][2:0]                     fmt_sign;
  logic signed [NUM_FORMATS-1:0][2:0][SUPER_EXP_BITS-1:0] fmt_exponent;
  logic        [NUM_FORMATS-1:0][2:0][SUPER_MAN_BITS-1:0] fmt_mantissa;

  fpnew_pkg::fp_info_t [NUM_FORMATS-1:0][2:0] info_q;

  // FP Input initialization
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : fmt_init_inputs
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (FpFmtConfig[fmt]) begin : active_format
      localparam fpnew_pkg::fp_format_e FpFormat = fpnew_pkg::fp_format_e'(fmt);
      logic [2:0][FP_WIDTH-1:0] trimmed_ops;

      // Classify input
      fpnew_classifier #(
        .FpFormat    ( FpFormat ),
        .NumOperands ( 3        )
      ) i_fpnew_classifier (
        .operands_i ( trimmed_ops                            ),
        .is_boxed_i ( inp_pipe_is_boxed_q[NUM_INP_REGS][fmt] ),
        .info_o     ( info_q[fmt]                            )
      );
      for (genvar op = 0; op < 3; op++) begin : gen_operands
        assign trimmed_ops[op]       = operands_q[op][FP_WIDTH-1:0];
        assign fmt_sign[fmt][op]     = operands_q[op][FP_WIDTH-1];
        assign fmt_exponent[fmt][op] = signed'({1'b0, operands_q[op][MAN_BITS+:EXP_BITS]});
        // Left-align the fraction in the super mantissa. The old shift
        // used a per-format amount; the implicit bit is appended later.
        assign fmt_mantissa[fmt][op] = {operands_q[op][MAN_BITS-1:0],
                                        {(SUPER_MAN_BITS - MAN_BITS){1'b0}}};
      end
    end else begin : inactive_format
      assign info_q[fmt]                 = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_sign[fmt]               = fpnew_pkg::DONT_CARE;             // format disabled
      assign fmt_exponent[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_mantissa[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
    end
  end

  fp_t                 operand_a, operand_b, operand_c;
  fpnew_pkg::fp_info_t info_a,    info_b,    info_c;

  // Constant biases. Parallel compares, not fpnew_pkg::bias (2**(exp-1)-1).
  localparam logic [SUPER_EXP_BITS-1:0] BIAS64 = SUPER_EXP_BITS'(1023);
  localparam logic [SUPER_EXP_BITS-1:0] BIAS32 = SUPER_EXP_BITS'(127);
  localparam logic [SUPER_EXP_BITS-1:0] BIAS16 = SUPER_EXP_BITS'(15);

  logic [SUPER_EXP_BITS-1:0] bias_src_w, bias_src2_w, bias_dst_w;
  assign bias_src_w =
      ({SUPER_EXP_BITS{src_fmt_q == fpnew_pkg::FP64}} & BIAS64)
    | ({SUPER_EXP_BITS{src_fmt_q == fpnew_pkg::FP32}} & BIAS32)
    | ({SUPER_EXP_BITS{src_fmt_q == fpnew_pkg::FP16ALT}} & BIAS32)
    | ({SUPER_EXP_BITS{src_fmt_q == fpnew_pkg::FP16}} & BIAS16)
    | ({SUPER_EXP_BITS{src_fmt_q == fpnew_pkg::FP8}} & BIAS16);
  assign bias_src2_w =
      ({SUPER_EXP_BITS{src2_fmt_q == fpnew_pkg::FP64}} & BIAS64)
    | ({SUPER_EXP_BITS{src2_fmt_q == fpnew_pkg::FP32}} & BIAS32)
    | ({SUPER_EXP_BITS{src2_fmt_q == fpnew_pkg::FP16ALT}} & BIAS32)
    | ({SUPER_EXP_BITS{src2_fmt_q == fpnew_pkg::FP16}} & BIAS16)
    | ({SUPER_EXP_BITS{src2_fmt_q == fpnew_pkg::FP8}} & BIAS16);
  assign bias_dst_w =
      ({SUPER_EXP_BITS{dst_fmt_q == fpnew_pkg::FP64}} & BIAS64)
    | ({SUPER_EXP_BITS{dst_fmt_q == fpnew_pkg::FP32}} & BIAS32)
    | ({SUPER_EXP_BITS{dst_fmt_q == fpnew_pkg::FP16ALT}} & BIAS32)
    | ({SUPER_EXP_BITS{dst_fmt_q == fpnew_pkg::FP16}} & BIAS16)
    | ({SUPER_EXP_BITS{dst_fmt_q == fpnew_pkg::FP8}} & BIAS16);

  // Operation selection and operand adjustment
  // | \c op_q  | \c op_mod_q | Operation Adjustment
  // |:--------:|:-----------:|---------------------
  // | FMADD    | \c 0        | FMADD: none
  // | FMADD    | \c 1        | FMSUB: Invert sign of operand C
  // | FNMSUB   | \c 0        | FNMSUB: Invert sign of operand A
  // | FNMSUB   | \c 1        | FNMADD: Invert sign of operands A and C
  // | ADD/ADDS | \c 0        | ADD: Set operand A to +1.0
  // | ADD/ADDS | \c 1        | SUB: Set operand A to +1.0, invert sign of operand C
  // | MUL      | \c 0        | MUL: Set operand C to +0.0 or -0.0 depending on the rounding mode
  // | *others* | \c -        | *invalid*
  // \note \c op_mod_q always inverts the sign of the addend.
  // Format mux and opcode adjust are parallel assigns. The old always_comb
  // billed later fields as depending on earlier ones.
  fpnew_pkg::operation_e op_q_sel;
  logic                  op_mod_sel, rnd_rdn, is_fnmsub, is_add, is_mul;
  logic                  sign_a_fmt, sign_b_fmt, sign_c_fmt;
  assign op_q_sel   = inp_pipe_op_q[NUM_INP_REGS];
  assign op_mod_sel = inp_pipe_op_mod_q[NUM_INP_REGS];
  assign rnd_rdn    = inp_pipe_rnd_mode_q[NUM_INP_REGS] == fpnew_pkg::RDN;
  assign is_fnmsub  = op_q_sel == fpnew_pkg::FNMSUB;
  assign is_add     = (op_q_sel == fpnew_pkg::ADD) || (op_q_sel == fpnew_pkg::ADDS);
  assign is_mul     = op_q_sel == fpnew_pkg::MUL;
  assign sign_a_fmt = fmt_sign[src_fmt_q][0];
  assign sign_b_fmt = fmt_sign[src_fmt_q][1];
  assign sign_c_fmt = fmt_sign[src2_fmt_q][2];

  assign operand_a.sign     = is_add ? 1'b0 : is_fnmsub ? ~sign_a_fmt : sign_a_fmt;
  assign operand_a.exponent = is_add ? signed'(bias_src_w) : fmt_exponent[src_fmt_q][0];
  assign operand_a.mantissa = is_add ? '0 : fmt_mantissa[src_fmt_q][0];
  assign operand_b.sign     = sign_b_fmt;
  assign operand_b.exponent = fmt_exponent[src_fmt_q][1];
  assign operand_b.mantissa = fmt_mantissa[src_fmt_q][1];
  // MUL replaces C, so op_mod does not stick to a multiply's addend.
  assign operand_c.sign     = is_mul ? ~rnd_rdn : (sign_c_fmt ^ op_mod_sel);
  assign operand_c.exponent = is_mul ? '0 : fmt_exponent[src2_fmt_q][2];
  assign operand_c.mantissa = is_mul ? '0 : fmt_mantissa[src2_fmt_q][2];

  assign info_a = is_add ? '{is_normal: 1'b1, is_boxed: 1'b1, default: 1'b0}
                         : info_q[src_fmt_q][0];
  assign info_b = info_q[src_fmt_q][1];
  assign info_c = is_mul ? '{is_zero: 1'b1, is_boxed: 1'b1, default: 1'b0}
                         : info_q[src2_fmt_q][2];

  // ---------------------
  // Input classification
  // ---------------------
  logic any_operand_inf;
  logic any_operand_nan;
  logic signalling_nan;
  logic effective_subtraction;
  logic tentative_sign;

  // Reduction for special case handling
  assign any_operand_inf = (| {info_a.is_inf,        info_b.is_inf,        info_c.is_inf});
  assign any_operand_nan = (| {info_a.is_nan,        info_b.is_nan,        info_c.is_nan});
  assign signalling_nan  = (| {info_a.is_signalling, info_b.is_signalling, info_c.is_signalling});
  // Effective subtraction in FMA occurs when product and addend signs differ
  assign effective_subtraction = operand_a.sign ^ operand_b.sign ^ operand_c.sign;
  // The tentative sign of the FMA shall be the sign of the product
  assign tentative_sign = operand_a.sign ^ operand_b.sign;

  // ----------------------
  // Special case handling
  // ----------------------
  logic [WIDTH-1:0]   special_result;
  fpnew_pkg::status_t special_status;
  logic               result_is_special;

  logic [NUM_FORMATS-1:0][WIDTH-1:0]    fmt_special_result;
  fpnew_pkg::status_t [NUM_FORMATS-1:0] fmt_special_status;
  logic [NUM_FORMATS-1:0]               fmt_result_is_special;


  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_special_results
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    localparam logic [EXP_BITS-1:0] QNAN_EXPONENT = '1;
    localparam logic [MAN_BITS-1:0] QNAN_MANTISSA = 2**(MAN_BITS-1);
    localparam logic [MAN_BITS-1:0] ZERO_MANTISSA = '0;

    if (FpFmtConfig[fmt]) begin : active_format
      always_comb begin : special_results
        logic [FP_WIDTH-1:0] special_res;

        // Default assignment
        special_res                = {1'b0, QNAN_EXPONENT, QNAN_MANTISSA}; // qNaN
        fmt_special_status[fmt]    = '0;
        fmt_result_is_special[fmt] = 1'b0;

        // Handle potentially mixed nan & infinity input => important for the case where infinity and
        // zero are multiplied and added to a qnan.
        // RISC-V mandates raising the NV exception in these cases:
        // (inf * 0) + c or (0 * inf) + c INVALID, no matter c (even quiet NaNs)
        if ((info_a.is_inf && info_b.is_zero) || (info_a.is_zero && info_b.is_inf)) begin
          fmt_result_is_special[fmt] = 1'b1; // bypass FMA, output is the canonical qNaN
          fmt_special_status[fmt].NV = 1'b1; // invalid operation
        // NaN Inputs cause canonical quiet NaN at the output and maybe invalid OP
        end else if (any_operand_nan) begin
          fmt_result_is_special[fmt] = 1'b1;           // bypass FMA, output is the canonical qNaN
          fmt_special_status[fmt].NV = signalling_nan; // raise the invalid operation flag if signalling
        // Special cases involving infinity
        end else if (any_operand_inf) begin
          fmt_result_is_special[fmt] = 1'b1; // bypass FMA
          // Effective addition of opposite infinities (±inf - ±inf) is invalid!
          if ((info_a.is_inf || info_b.is_inf) && info_c.is_inf && effective_subtraction)
            fmt_special_status[fmt].NV = 1'b1; // invalid operation
          // Handle cases where output will be inf because of inf product input
          else if (info_a.is_inf || info_b.is_inf) begin
            // Result is infinity with the sign of the product
            special_res = {operand_a.sign ^ operand_b.sign, QNAN_EXPONENT, ZERO_MANTISSA};
          // Handle cases where the addend is inf
          end else if (info_c.is_inf) begin
            // Result is inifinity with sign of the addend (= operand_c)
            special_res = {operand_c.sign, QNAN_EXPONENT, ZERO_MANTISSA};
          end
        end
        // Initialize special result with ones (NaN-box)
        fmt_special_result[fmt]               = '1;
        fmt_special_result[fmt][FP_WIDTH-1:0] = special_res;
      end
    end else begin : inactive_format
      assign fmt_special_result[fmt] = '{default: fpnew_pkg::DONT_CARE};
      assign fmt_special_status[fmt] = '0;
      assign fmt_result_is_special[fmt] = 1'b0;
    end
  end

  // Detect special case from source format, I2F casts don't produce a special result
  assign result_is_special = fmt_result_is_special[dst_fmt_q]; // they're all the same
  // Signalling input NaNs raise invalid flag, otherwise no flags set
  assign special_status = fmt_special_status[dst_fmt_q];
  // Assemble result according to destination format
  assign special_result = fmt_special_result[dst_fmt_q]; // destination format

  // ---------------------------
  // Initial exponent data path
  // ---------------------------
  logic signed [EXP_WIDTH-1:0] exponent_a, exponent_b, exponent_c;
  logic signed [EXP_WIDTH-1:0] exponent_addend, exponent_product, exponent_difference;
  logic signed [EXP_WIDTH-1:0] tentative_exponent;

  // Zero-extend exponents into signed container - implicit width extension
  assign exponent_a = signed'({1'b0, operand_a.exponent});
  assign exponent_b = signed'({1'b0, operand_b.exponent});
  assign exponent_c = signed'({1'b0, operand_c.exponent});

  // Calculate internal exponents from encoded values. Real exponents are (ex = Ex - bias + 1 - nx)
  // with Ex the encoded exponent and nx the implicit bit. Internal exponents are biased to dst fmt.
  assign exponent_addend = info_c.is_zero ? 1 // in case the addend is zero, set minimum exp
                           : signed'(exponent_c + $signed({1'b0, ~info_c.is_normal}) // 0 as subnorm
                                     - signed'(EXP_WIDTH'(bias_src2_w))
                                     + signed'(EXP_WIDTH'(bias_dst_w))); // rebias for dst fmt
  // Biased product exponent is the sum of encoded exponents minus the bias.
  assign exponent_product = (info_a.is_zero || info_b.is_zero) // in case the product is zero, set minimum exp.
                            ? 2 - signed'(EXP_WIDTH'(bias_dst_w))
                            : signed'(exponent_a + info_a.is_subnormal
                                      + exponent_b + info_b.is_subnormal
                                      - 2*signed'(EXP_WIDTH'(bias_src_w))
                                      + signed'(EXP_WIDTH'(bias_dst_w))); // rebias for dst fmt
  // Exponent difference is the addend exponent minus the product exponent
  assign exponent_difference = exponent_addend - exponent_product;

  // ------------------
  // Product data path
  // ------------------
  logic [PRECISION_BITS-1:0]   mantissa_a, mantissa_b, mantissa_c;
  logic [2*PRECISION_BITS-1:0] product;             // the p*p product is 2p bits wide
  logic [3*PRECISION_BITS+3:0] product_shifted;     // addends are 3p+4 bit wide (including G/R)

  // Add implicit bits to mantissae
  assign mantissa_a = {info_a.is_normal, operand_a.mantissa};
  assign mantissa_b = {info_b.is_normal, operand_b.mantissa};
  assign mantissa_c = {info_c.is_normal, operand_c.mantissa};

  // Explicit cut before the mantissa multiply. Generated FFL pipes are not a
  // measured register, and the module default NumPipeRegs is 0, so the
  // exponent sum, the  mantissa product, and the normalize chain were one
  // cone. out_valid follows exp_valid_q. This unit is generate-dead on hyp8
  // (ADDMUL is PARALLEL; the live FMA is fpnew_fma). The extra cycle is not
  // added to LAT_FMA. Valid is captured with the operands it qualifies.
  logic                            exp_ready, exp_valid_q, exp_ena;
  logic signed [EXP_WIDTH-1:0]     exp_a_h, exp_b_h, exp_c_h;
  logic signed [EXP_WIDTH-1:0]     exp_add_h, exp_prod_h, exp_diff_h;
  logic                            z_a_h, z_b_h, z_c_h, sub_a_h, sub_b_h, nrm_c_h;
  logic [SUPER_EXP_BITS-1:0]       bias_s_h, bias_2_h, bias_d_h;
  logic [PRECISION_BITS-1:0]       mant_a_h, mant_b_h, mant_c_h;
  logic [SUPER_MAN_BITS-1:0]       man_c_raw_h;
  fpnew_pkg::fp_info_t             info_c_h;
  logic                            eff_sub_h, tent_sign_h, res_special_h, exp_mask_h;
  logic [WIDTH-1:0]                special_res_h;
  fpnew_pkg::status_t              special_stat_h;
  fpnew_pkg::roundmode_e           exp_rnd_h;
  fpnew_pkg::fp_format_e           exp_dst_h;
  TagType                          exp_tag_h;
  AuxType                          exp_aux_h;
  assign exp_ready = sum_ready | ~exp_valid_q;
  assign exp_ena   = exp_ready & inp_pipe_valid_q[NUM_INP_REGS];
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_exp_valid
    if (!rst_ni) exp_valid_q <= 1'b0;
    else if (flush_i) exp_valid_q <= 1'b0;
    else if (exp_ready) exp_valid_q <= inp_pipe_valid_q[NUM_INP_REGS];
  end
  // Raw exponent fields, each in its own flop. The sum is after these
  // so a format mux is not added to the bias compare or the add.
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_ea
    if (!rst_ni) exp_a_h <= '0;
    else if (exp_ena) exp_a_h <= exponent_a;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_eb
    if (!rst_ni) exp_b_h <= '0;
    else if (exp_ena) exp_b_h <= exponent_b;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_ec
    if (!rst_ni) exp_c_h <= '0;
    else if (exp_ena) exp_c_h <= exponent_c;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_ez
    if (!rst_ni) begin
      z_a_h <= 1'b0; z_b_h <= 1'b0; z_c_h <= 1'b0;
      sub_a_h <= 1'b0; sub_b_h <= 1'b0; nrm_c_h <= 1'b0;
    end else if (exp_ena) begin
      z_a_h <= info_a.is_zero; z_b_h <= info_b.is_zero; z_c_h <= info_c.is_zero;
      sub_a_h <= info_a.is_subnormal; sub_b_h <= info_b.is_subnormal;
      nrm_c_h <= info_c.is_normal;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_bs
    if (!rst_ni) bias_s_h <= '0;
    else if (exp_ena) bias_s_h <= bias_src_w;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_b2
    if (!rst_ni) bias_2_h <= '0;
    else if (exp_ena) bias_2_h <= bias_src2_w;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_bd
    if (!rst_ni) bias_d_h <= '0;
    else if (exp_ena) bias_d_h <= bias_dst_w;
  end
  assign exp_add_h = z_c_h ? EXP_WIDTH'(1)
                   : signed'(exp_c_h + $signed({1'b0, ~nrm_c_h})
                             - signed'(EXP_WIDTH'(bias_2_h))
                             + signed'(EXP_WIDTH'(bias_d_h)));
  assign exp_prod_h = (z_a_h || z_b_h)
                    ? signed'(EXP_WIDTH'(2) - signed'(EXP_WIDTH'(bias_d_h)))
                    : signed'(exp_a_h + $signed({1'b0, sub_a_h})
                              + exp_b_h + $signed({1'b0, sub_b_h})
                              - (signed'(EXP_WIDTH'(bias_s_h)) << 1)
                              + signed'(EXP_WIDTH'(bias_d_h)));
  assign exp_diff_h = exp_add_h - exp_prod_h;
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_exp_mant
    if (!rst_ni) begin
      mant_a_h    <= '0;
      mant_b_h    <= '0;
      mant_c_h    <= '0;
      man_c_raw_h <= '0;
      info_c_h    <= '0;
    end else if (exp_ena) begin
      mant_a_h    <= mantissa_a;
      mant_b_h    <= mantissa_b;
      mant_c_h    <= mantissa_c;
      man_c_raw_h <= operand_c.mantissa;
      info_c_h    <= info_c;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_exp_ctl
    if (!rst_ni) begin
      eff_sub_h      <= 1'b0;
      tent_sign_h    <= 1'b0;
      res_special_h  <= 1'b0;
      special_res_h  <= '0;
      special_stat_h <= '0;
      exp_rnd_h      <= fpnew_pkg::RNE;
      exp_dst_h      <= fpnew_pkg::fp_format_e'(0);
      exp_tag_h      <= TagType'('0);
      exp_mask_h     <= 1'b0;
      exp_aux_h      <= AuxType'('0);
    end else if (exp_ena) begin
      eff_sub_h      <= effective_subtraction;
      tent_sign_h    <= tentative_sign;
      res_special_h  <= result_is_special;
      special_res_h  <= special_result;
      special_stat_h <= special_status;
      exp_rnd_h      <= inp_pipe_rnd_mode_q[NUM_INP_REGS];
      exp_dst_h      <= dst_fmt_q;
      exp_tag_h      <= inp_pipe_tag_q[NUM_INP_REGS];
      exp_mask_h     <= inp_pipe_mask_q[NUM_INP_REGS];
      exp_aux_h      <= inp_pipe_aux_q[NUM_INP_REGS];
    end
  end

  // Shift amount for addend based on the registered exponent difference.
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt;
  logic                          addend_sat, addend_overlap;
  assign addend_sat     = exp_diff_h <= signed'(-2 * PRECISION_BITS - 1);
  assign addend_overlap = !addend_sat && (exp_diff_h <= signed'(PRECISION_BITS + 2));
  assign addend_shamt   = addend_sat ? (3 * PRECISION_BITS + 4)
                        : addend_overlap ? unsigned'(signed'(PRECISION_BITS) + 3 - exp_diff_h)
                        : '0;

  // LZC for addend normalization, after the exponent register.
  logic        [$clog2(SUPER_MAN_BITS)-1:0] addend_lzc_count;
  logic        [$clog2(SUPER_MAN_BITS)  :0] addend_lzc_count_sgn;
  logic        [SHIFT_AMOUNT_WIDTH    -1:0] addend_normalize_shamt;
  logic                                     addend_is_norm_or_zero, addend_stays_sub, addend_can_norm;

  lzc #(
    .WIDTH ( SUPER_MAN_BITS ),
    .MODE  ( 1              ) // MODE = 1 counts leading zeroes
  ) i_addend_lzc (
    .in_i    ( man_c_raw_h      ),
    .cnt_o   ( addend_lzc_count ),
    .empty_o (                  )
  );

  assign addend_lzc_count_sgn = signed'({1'b0, addend_lzc_count});

  // Same priority as the old if/else: normal/zero, then still-subnormal,
  // then a subnormal that normalizes, else a partial normalize.
  assign addend_is_norm_or_zero = info_c_h.is_normal || info_c_h.is_zero;
  assign addend_stays_sub       = !addend_is_norm_or_zero && (exp_add_h <= 1);
  assign addend_can_norm        = !addend_is_norm_or_zero && !addend_stays_sub
                               && ((addend_lzc_count_sgn + 1) < exp_add_h);
  assign addend_normalize_shamt = (addend_is_norm_or_zero || addend_stays_sub) ? '0
                                : addend_can_norm ? (addend_lzc_count + 1)
                                : SHIFT_AMOUNT_WIDTH'(exp_add_h - 1);

  // The tentative exponent will be the larger of the product or addend exponent
  assign tentative_exponent = (exp_diff_h > 0) ? exp_add_h - addend_normalize_shamt : exp_prod_h;

  // Mantissa multiplier (a*b) from the registered mantissae.
  assign product = mant_a_h * mant_b_h;

  // Product is placed into a 3p+4 bit wide vector, padded with 2 bits for round and sticky:
  // | 000...000 | product | RS |
  //  <-  p+2  -> <-  2p -> < 2>
  assign product_shifted = product << 2; // constant shift

  // -----------------
  // Addend data path
  // -----------------
  logic [3*PRECISION_BITS+3:0] addend_after_shift;  // upper 3p+4 bits are needed to go on
  logic [PRECISION_BITS-1:0]   addend_sticky_bits;  // up to p bit of shifted addend are sticky
  logic                        sticky_before_add;   // they are compressed into a single sticky bit
  logic [3*PRECISION_BITS+3:0] addend_shifted;      // addends are 3p+4 bit wide (including G/R)
  logic                        inject_carry_in;     // inject carry for subtractions if needed

  // In parallel, the addend is right-shifted according to the exponent difference. Up to p bits are
  // shifted out and compressed into a sticky bit.
  // BEFORE THE SHIFT:
  // | mantissa_c | 000..000 |
  //  <-    p   -> <- 3p+4 ->
  // AFTER THE SHIFT:
  // | 000..........000 | mantissa_c | 000...............0GR |  sticky bits  |
  //  <- addend_shamt -> <-    p   -> <- 2p+4-addend_shamt -> <-  up to p  ->
  assign {addend_after_shift, addend_sticky_bits} =
      (mant_c_h << (3 * PRECISION_BITS + 4)) >> addend_shamt;

  assign sticky_before_add     = (| addend_sticky_bits);

  // In case of a subtraction, the addend is inverted
  assign addend_shifted = eff_sub_h ? ~addend_after_shift : addend_after_shift;
  assign inject_carry_in = eff_sub_h & ~sticky_before_add;

  // ------
  // Adder
  // ------
  logic [3*PRECISION_BITS+4:0] sum_pos, sum_neg; // added one bit for the carry
  logic                        sum_carry;        // observe carry bit from positive sum for sign fixing
  logic [3*PRECISION_BITS+3:0] sum;              // discard carry as sum won't overflow
  logic                        final_sign;

  //Mantissa adder (ab+c). In normal addition, it cannot overflow.
  assign sum_pos = product_shifted + addend_shifted + inject_carry_in;
  assign sum_carry = sum_pos[3*PRECISION_BITS+4];

  // Parallel adder for negative sum (only used for effective subtractions).
  // Note: inject_carry_in is used to complete the negation of the addend in the positive sum but
  // for the negative sum the addend is not negated, so no carry needs to be injected.
  assign sum_neg = addend_after_shift - product_shifted;

  // Complement negative sum (can only happen in subtraction -> overflows for positive results)
  assign sum        = (eff_sub_h && ~sum_carry) ? sum_neg : sum_pos;

  // In case of a mispredicted subtraction result, do a sign flip
  assign final_sign = (eff_sub_h && (sum_carry == tent_sign_h))
                      ? 1'b1
                      : (eff_sub_h ? 1'b0 : tent_sign_h);

  // ------
  // Leading Zero Anticipator
  // ------
  logic [LZC_RESULT_WIDTH-1:0] lza_count;

  fmalza #(
    .WIDTH ( LOWER_SUM_WIDTH      ),
    .NF    ( PRECISION_BITS-1     )
  ) i_fmalza (
    .A    ( addend_shifted[LOWER_SUM_WIDTH-1:0] ),
    .Pm   ( product                             ),
    .Cin  ( inject_carry_in                     ),
    .sub  ( eff_sub_h                           ),
    .SCnt ( lza_count                           )
  );


  // ---------------
  // Internal pipeline
  // ---------------
  // Pipeline output signals as non-arrays
  logic                          effective_subtraction_q;
  logic signed [EXP_WIDTH-1:0]   exponent_product_q;
  logic signed [EXP_WIDTH-1:0]   exponent_difference_q;
  logic signed [EXP_WIDTH-1:0]   tentative_exponent_q;
  logic [SHIFT_AMOUNT_WIDTH-1:0] addend_shamt_q;
  logic                          sticky_before_add_q;
  logic                          sticky_n_q, sign_n_q, eff_n_q, spec_n_q, mask_n_q;
  logic                          norm_ready, norm_valid_q, norm_ena;
  logic [3*PRECISION_BITS+4:0]   sum_shifted_q;
  logic signed [EXP_WIDTH-1:0]   norm_exp_q;
  fpnew_pkg::roundmode_e         rnd_n_q;
  fpnew_pkg::fp_format_e         dst_n_q;
  fp_t                           spec_res_n_q;
  fpnew_pkg::status_t            spec_stat_n_q;
  TagType                        tag_n_q;
  AuxType                        aux_n_q;
  logic [3*PRECISION_BITS+3:0]   sum_q;
  logic [LZC_RESULT_WIDTH-1:0]   lza_count_q;
  logic                          final_sign_q;
  fpnew_pkg::fp_format_e         dst_fmt_q2;
  fpnew_pkg::roundmode_e         rnd_mode_q;
  logic                          result_is_special_q;
  fp_t                           special_result_q;
  fpnew_pkg::status_t            special_status_q;
  // Internal pipeline signals, index i holds signal after i register stages
  logic                  [0:NUM_MID_REGS]                         mid_pipe_eff_sub_q;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH-1:0]          mid_pipe_exp_prod_q;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH-1:0]          mid_pipe_exp_diff_q;
  logic signed           [0:NUM_MID_REGS][EXP_WIDTH-1:0]          mid_pipe_tent_exp_q;
  logic                  [0:NUM_MID_REGS][SHIFT_AMOUNT_WIDTH-1:0] mid_pipe_add_shamt_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_sticky_q;
  logic                  [0:NUM_MID_REGS][3*PRECISION_BITS+3:0]   mid_pipe_sum_q;
  logic                  [0:NUM_MID_REGS][LZC_RESULT_WIDTH-1:0]   mid_pipe_lza_count_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_final_sign_q;
  fpnew_pkg::roundmode_e [0:NUM_MID_REGS]                         mid_pipe_rnd_mode_q;
  fpnew_pkg::fp_format_e [0:NUM_MID_REGS]                         mid_pipe_dst_fmt_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_res_is_spec_q;
  fp_t                   [0:NUM_MID_REGS]                         mid_pipe_spec_res_q;
  fpnew_pkg::status_t    [0:NUM_MID_REGS]                         mid_pipe_spec_stat_q;
  TagType                [0:NUM_MID_REGS]                         mid_pipe_tag_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_mask_q;
  AuxType                [0:NUM_MID_REGS]                         mid_pipe_aux_q;
  logic                  [0:NUM_MID_REGS]                         mid_pipe_valid_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_MID_REGS] mid_pipe_ready;

  // Second explicit cut, after the product and the sum. The multiply stays
  // on the cone into these flops (multi-cycle). Normalize and round read
  // the flops, so they are not added to that product cone. Valid moves
  // with the sum. NumPipeRegs is unchanged.
  logic                            sum_ready, sum_valid_q, sum_ena;
  logic                            sum_eff_h, sum_sticky_h, sum_sign_h, sum_spec_h, sum_mask_h;
  logic signed [EXP_WIDTH-1:0]     sum_exp_prod_h, sum_exp_diff_h, sum_tent_h;
  logic [SHIFT_AMOUNT_WIDTH-1:0]   sum_shamt_h;
  logic [3*PRECISION_BITS+3:0]     sum_sum_h;
  logic [LZC_RESULT_WIDTH-1:0]     sum_lza_h;
  fpnew_pkg::roundmode_e           sum_rnd_h;
  fpnew_pkg::fp_format_e           sum_dst_h;
  fp_t                             sum_spec_res_h;
  fpnew_pkg::status_t              sum_spec_stat_h;
  TagType                          sum_tag_h;
  AuxType                          sum_aux_h;
  assign sum_ready = mid_pipe_ready[0] | ~sum_valid_q;
  assign sum_ena   = sum_ready & exp_valid_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_sum_valid
    if (!rst_ni) sum_valid_q <= 1'b0;
    else if (flush_i) sum_valid_q <= 1'b0;
    else if (sum_ready) sum_valid_q <= exp_valid_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_sum_acc
    if (!rst_ni) sum_sum_h <= '0;
    else if (sum_ena) sum_sum_h <= sum;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_sum_lza
    if (!rst_ni) sum_lza_h <= '0;
    else if (sum_ena) sum_lza_h <= lza_count;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_sum_shamt
    if (!rst_ni) sum_shamt_h <= '0;
    else if (sum_ena) sum_shamt_h <= addend_shamt + addend_normalize_shamt;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_sum_flag
    if (!rst_ni) begin
      sum_sticky_h <= 1'b0;
      sum_sign_h   <= 1'b0;
      sum_eff_h    <= 1'b0;
    end else if (sum_ena) begin
      sum_sticky_h <= sticky_before_add;
      sum_sign_h   <= final_sign;
      sum_eff_h    <= eff_sub_h;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_sum_exp
    if (!rst_ni) begin
      sum_exp_prod_h <= '0;
      sum_exp_diff_h <= '0;
      sum_tent_h     <= '0;
    end else if (sum_ena) begin
      sum_exp_prod_h <= exp_prod_h;
      sum_exp_diff_h <= exp_diff_h;
      sum_tent_h     <= tentative_exponent;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_sum_ctl
    if (!rst_ni) begin
      sum_rnd_h       <= fpnew_pkg::RNE;
      sum_dst_h       <= fpnew_pkg::fp_format_e'(0);
      sum_spec_h      <= 1'b0;
      sum_spec_res_h  <= '0;
      sum_spec_stat_h <= '0;
      sum_tag_h       <= TagType'('0);
      sum_mask_h      <= 1'b0;
      sum_aux_h       <= AuxType'('0);
    end else if (sum_ena) begin
      sum_rnd_h       <= exp_rnd_h;
      sum_dst_h       <= exp_dst_h;
      sum_spec_h      <= res_special_h;
      sum_spec_res_h  <= special_res_h;
      sum_spec_stat_h <= special_stat_h;
      sum_tag_h       <= exp_tag_h;
      sum_mask_h      <= exp_mask_h;
      sum_aux_h       <= exp_aux_h;
    end
  end

  // Input stage: First element of pipeline is taken from the sum register.
  assign mid_pipe_eff_sub_q[0]     = sum_eff_h;
  assign mid_pipe_exp_prod_q[0]    = sum_exp_prod_h;
  assign mid_pipe_exp_diff_q[0]    = sum_exp_diff_h;
  assign mid_pipe_tent_exp_q[0]    = sum_tent_h;
  assign mid_pipe_add_shamt_q[0]   = sum_shamt_h;
  assign mid_pipe_sticky_q[0]      = sum_sticky_h;
  assign mid_pipe_sum_q[0]         = sum_sum_h;
  assign mid_pipe_lza_count_q[0]   = sum_lza_h;
  assign mid_pipe_final_sign_q[0]  = sum_sign_h;
  assign mid_pipe_rnd_mode_q[0]    = sum_rnd_h;
  assign mid_pipe_dst_fmt_q[0]     = sum_dst_h;
  assign mid_pipe_res_is_spec_q[0] = sum_spec_h;
  assign mid_pipe_spec_res_q[0]    = sum_spec_res_h;
  assign mid_pipe_spec_stat_q[0]   = sum_spec_stat_h;
  assign mid_pipe_tag_q[0]         = sum_tag_h;
  assign mid_pipe_mask_q[0]        = sum_mask_h;
  assign mid_pipe_aux_q[0]         = sum_aux_h;
  assign mid_pipe_valid_q[0]       = sum_valid_q;
  // Input stage: ready comes from the explicit exponent register.
  assign inp_pipe_ready[NUM_INP_REGS] = exp_ready;

  // Generate the register stages
  for (genvar i = 0; i < NUM_MID_REGS; i++) begin : gen_inside_pipeline
    // Internal register enable for this stage
    logic reg_ena;
    // Determine the ready signal of the current stage - advance the pipeline:
    // 1. if the next stage is ready for our data
    // 2. if the next stage only holds a bubble (not valid) -> we can pop it
    assign mid_pipe_ready[i] = mid_pipe_ready[i+1] | ~mid_pipe_valid_q[i+1];
    // Valid: enabled by ready signal, synchronous clear with the flush signal
    `FFLARNC(mid_pipe_valid_q[i+1], mid_pipe_valid_q[i], mid_pipe_ready[i], flush_i, 1'b0, clk_i, rst_ni)
    // Enable register if pipleine ready and a valid data item is present
    assign reg_ena = (mid_pipe_ready[i] & mid_pipe_valid_q[i]) | reg_ena_i[NUM_INP_REGS + i];
    // Generate the pipeline registers within the stages, use enable-registers
    `FFL(mid_pipe_eff_sub_q[i+1],     mid_pipe_eff_sub_q[i],     reg_ena, '0)
    `FFL(mid_pipe_exp_prod_q[i+1],    mid_pipe_exp_prod_q[i],    reg_ena, '0)
    `FFL(mid_pipe_exp_diff_q[i+1],    mid_pipe_exp_diff_q[i],    reg_ena, '0)
    `FFL(mid_pipe_tent_exp_q[i+1],    mid_pipe_tent_exp_q[i],    reg_ena, '0)
    `FFL(mid_pipe_add_shamt_q[i+1],   mid_pipe_add_shamt_q[i],   reg_ena, '0)
    `FFL(mid_pipe_sticky_q[i+1],      mid_pipe_sticky_q[i],      reg_ena, '0)
    `FFL(mid_pipe_sum_q[i+1],         mid_pipe_sum_q[i],         reg_ena, '0)
    `FFL(mid_pipe_lza_count_q[i+1],   mid_pipe_lza_count_q[i],   reg_ena, '0)
    `FFL(mid_pipe_final_sign_q[i+1],  mid_pipe_final_sign_q[i],  reg_ena, '0)
    `FFL(mid_pipe_rnd_mode_q[i+1],    mid_pipe_rnd_mode_q[i],    reg_ena, fpnew_pkg::RNE)
    `FFL(mid_pipe_dst_fmt_q[i+1],     mid_pipe_dst_fmt_q[i],     reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(mid_pipe_res_is_spec_q[i+1], mid_pipe_res_is_spec_q[i], reg_ena, '0)
    `FFL(mid_pipe_spec_res_q[i+1],    mid_pipe_spec_res_q[i],    reg_ena, '0)
    `FFL(mid_pipe_spec_stat_q[i+1],   mid_pipe_spec_stat_q[i],   reg_ena, '0)
    `FFL(mid_pipe_tag_q[i+1],         mid_pipe_tag_q[i],         reg_ena, TagType'('0))
    `FFL(mid_pipe_mask_q[i+1],        mid_pipe_mask_q[i],        reg_ena, '0)
    `FFL(mid_pipe_aux_q[i+1],         mid_pipe_aux_q[i],         reg_ena, AuxType'('0))
  end
  // Output stage: assign selected pipe outputs to signals for later use
  assign effective_subtraction_q = mid_pipe_eff_sub_q[NUM_MID_REGS];
  assign exponent_product_q      = mid_pipe_exp_prod_q[NUM_MID_REGS];
  assign exponent_difference_q   = mid_pipe_exp_diff_q[NUM_MID_REGS];
  assign tentative_exponent_q    = mid_pipe_tent_exp_q[NUM_MID_REGS];
  assign addend_shamt_q          = mid_pipe_add_shamt_q[NUM_MID_REGS];
  assign sticky_before_add_q     = sticky_n_q;
  assign sum_q                   = mid_pipe_sum_q[NUM_MID_REGS];
  assign lza_count_q             = mid_pipe_lza_count_q[NUM_MID_REGS];
  assign final_sign_q            = sign_n_q;
  assign rnd_mode_q              = rnd_n_q;
  assign dst_fmt_q2              = dst_n_q;
  assign result_is_special_q     = spec_n_q;
  assign special_result_q        = spec_res_n_q;
  assign special_status_q        = spec_stat_n_q;

  // --------------
  // Normalization
  // --------------
  logic        [LOWER_SUM_WIDTH-1:0]  sum_lower;              // lower 2p+3 bits of sum are searched
  logic        [LZC_RESULT_WIDTH-1:0] leading_zero_count;     // the number of leading zeroes
  logic signed [LZC_RESULT_WIDTH:0]   leading_zero_count_sgn; // signed leading-zero count
  logic                               sum_lower_zero;         // in case only zeroes found
  logic        [LOWER_SUM_WIDTH:0]    least_leading_0_onehot; // onehot encoded least leading 0
  logic                               lza_overpredict;        // LZA over-predicted actual LZC by 1

  logic        [SHIFT_AMOUNT_WIDTH-1:0] norm_shamt; // Normalization shift amount
  logic signed [EXP_WIDTH-1:0]          normalized_exponent;

  logic [3*PRECISION_BITS+4:0] sum_shifted;       // result after first normalization shift
  logic [PRECISION_BITS:0]     final_mantissa;    // final mantissa before rounding with round bit
  logic [2*PRECISION_BITS+2:0] sum_sticky_bits;   // remaining 2p+3 sticky bits after normalization
  logic                        sticky_after_norm; // sticky bit after normalization

  logic signed [EXP_WIDTH-1:0] final_exponent;

  assign sum_lower = sum_q[LOWER_SUM_WIDTH-1:0];

  assign sum_lower_zero = sum_lower == '0;

  // A carry might have propagated into the least leading 0 bit (the lowest 0 bits just before the
  // first 1 bit) predicted by the LZA.
  // Note: This is a mux that only looks at `sum_q[LOWER_SUM_WIDTH:0]`.
  assign least_leading_0_onehot = {1'b1, {LOWER_SUM_WIDTH{1'b0}}} >> lza_count_q;
  assign lza_overpredict        = |(sum_q[LOWER_SUM_WIDTH:0] & least_leading_0_onehot);

  // Get actual LZC by correcting LZA in case of over-prediction
  assign leading_zero_count     = lza_overpredict ? lza_count_q - 1 : lza_count_q;
  assign leading_zero_count_sgn = signed'({1'b0, leading_zero_count});

  // Product-anchored and subnormal arms are parallel. The old priority
  // if billed every arm in front of the last one. The over-predict fix
  // (exponent 1) only applies in the product-anchored subnormal arm.
  logic prod_anchor, norm_ok, sub_fix, use_norm, use_fix, use_add;
  logic [SHIFT_AMOUNT_WIDTH-1:0] sh_norm, sh_sub;
  logic [EXP_WIDTH-1:0] ex_norm_b, ex_fix_b, ex_add_b;
  assign prod_anchor = (exponent_difference_q <= 0)
                    || (effective_subtraction_q && (exponent_difference_q <= 2));
  assign norm_ok = ((exponent_product_q - signed'({1'b0, lza_count_q}) + 1) >= 0)
                && !sum_lower_zero;
  assign sub_fix = !norm_ok
                && ((exponent_product_q - leading_zero_count_sgn + 1) >= 0)
                && !sum_lower_zero;
  assign use_norm = prod_anchor && norm_ok;
  assign use_fix  = prod_anchor && sub_fix;
  assign use_add  = !prod_anchor;
  assign sh_norm  = SHIFT_AMOUNT_WIDTH'(PRECISION_BITS + 1 + lza_count_q);
  assign sh_sub   = unsigned'(signed'(PRECISION_BITS + 2 + exponent_product_q));
  // One-hot OR, so the three shift amounts are parallel arms.
  assign norm_shamt = ({SHIFT_AMOUNT_WIDTH{use_norm}} & sh_norm)
                    | ({SHIFT_AMOUNT_WIDTH{prod_anchor && !norm_ok}} & sh_sub)
                    | ({SHIFT_AMOUNT_WIDTH{use_add}} & addend_shamt_q);
  assign ex_norm_b = EXP_WIDTH'(exponent_product_q - signed'({1'b0, lza_count_q}) + 2);
  assign ex_fix_b  = EXP_WIDTH'(1);
  assign ex_add_b  = EXP_WIDTH'(tentative_exponent_q);
  assign normalized_exponent = signed'(
        ({EXP_WIDTH{use_norm}} & ex_norm_b)
      | ({EXP_WIDTH{use_fix}}  & ex_fix_b)
      | ({EXP_WIDTH{use_add}}  & ex_add_b));

  // Do the large normalization shift
  assign sum_shifted       = sum_q << norm_shamt;

  // Cut after the normalize barrel. Round reads the registered shift.
  // Valid moves with that shift. This is a generate-dead unit on hyp8
  // (ADDMUL is PARALLEL), so LAT_FMA is unchanged.
  assign norm_ready = out_pipe_ready[0] | ~norm_valid_q;
  assign norm_ena   = norm_ready & mid_pipe_valid_q[NUM_MID_REGS];
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_norm_valid
    if (!rst_ni) norm_valid_q <= 1'b0;
    else if (flush_i) norm_valid_q <= 1'b0;
    else if (norm_ready) norm_valid_q <= mid_pipe_valid_q[NUM_MID_REGS];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_norm_sum
    if (!rst_ni) sum_shifted_q <= '0;
    else if (norm_ena) sum_shifted_q <= sum_shifted;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_norm_exp
    if (!rst_ni) norm_exp_q <= '0;
    else if (norm_ena) norm_exp_q <= normalized_exponent;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_fma_norm_ctl
    if (!rst_ni) begin
      sticky_n_q    <= 1'b0;
      sign_n_q      <= 1'b0;
      eff_n_q       <= 1'b0;
      rnd_n_q       <= fpnew_pkg::RNE;
      dst_n_q       <= fpnew_pkg::fp_format_e'(0);
      spec_n_q      <= 1'b0;
      spec_res_n_q  <= '0;
      spec_stat_n_q <= '0;
      tag_n_q       <= TagType'('0);
      mask_n_q      <= 1'b0;
      aux_n_q       <= AuxType'('0);
    end else if (norm_ena) begin
      sticky_n_q    <= mid_pipe_sticky_q[NUM_MID_REGS];
      sign_n_q      <= mid_pipe_final_sign_q[NUM_MID_REGS];
      eff_n_q       <= mid_pipe_eff_sub_q[NUM_MID_REGS];
      rnd_n_q       <= mid_pipe_rnd_mode_q[NUM_MID_REGS];
      dst_n_q       <= mid_pipe_dst_fmt_q[NUM_MID_REGS];
      spec_n_q      <= mid_pipe_res_is_spec_q[NUM_MID_REGS];
      spec_res_n_q  <= mid_pipe_spec_res_q[NUM_MID_REGS];
      spec_stat_n_q <= mid_pipe_spec_stat_q[NUM_MID_REGS];
      tag_n_q       <= mid_pipe_tag_q[NUM_MID_REGS];
      mask_n_q      <= mid_pipe_mask_q[NUM_MID_REGS];
      aux_n_q       <= mid_pipe_aux_q[NUM_MID_REGS];
    end
  end

  // One-bit normalization. Arms are exclusive: carry, then the leading one
  // already in place, then a denormal fixup, else a zero exponent.
  logic carry_bit, sum_msb, denorm_fix, exp_to_zero;
  assign carry_bit   = sum_shifted_q[3*PRECISION_BITS+4];
  assign sum_msb     = sum_shifted_q[3*PRECISION_BITS+3];
  assign denorm_fix  = !carry_bit && !sum_msb && (norm_exp_q > 1);
  assign exp_to_zero = !carry_bit && !sum_msb && !(norm_exp_q > 1);
  assign {final_mantissa, sum_sticky_bits} = carry_bit ? (sum_shifted_q >> 1)
                                          : denorm_fix ? (sum_shifted_q << 1)
                                          : sum_shifted_q;
  assign final_exponent = carry_bit ? (norm_exp_q + EXP_WIDTH'(1))
                        : denorm_fix ? (norm_exp_q - EXP_WIDTH'(1))
                        : exp_to_zero ? '0
                        : norm_exp_q;

  // Update the sticky bit with the shifted-out bits
  assign sticky_after_norm = (| {sum_sticky_bits}) | sticky_before_add_q;

  // ----------------------------
  // Rounding and classification
  // ----------------------------
  logic                                     pre_round_sign;
  logic [SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] pre_round_abs; // absolute value of result before rounding
  logic [1:0]                               round_sticky_bits;

  logic of_before_round, of_after_round; // overflow
  logic uf_before_round, uf_after_round; // underflow

  logic [NUM_FORMATS-1:0][SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] fmt_pre_round_abs; // per format
  logic [NUM_FORMATS-1:0][1:0]                               fmt_round_sticky_bits;

  logic [NUM_FORMATS-1:0]                                    fmt_of_after_round;
  logic [NUM_FORMATS-1:0]                                    fmt_uf_after_round;

  logic                                     rounded_sign;
  logic [SUPER_EXP_BITS+SUPER_MAN_BITS-1:0] rounded_abs; // absolute value of result after rounding
  logic                                     result_zero;

  // Infinity exponent per destination format. A runtime 2**(exp_bits)-1 is a
  // variable barrel; these arms are the IEEE all-ones exponents.
  logic [SUPER_EXP_BITS-1:0] exp_max_dst;
  always_comb begin : exp_max_dst_mux
    unique case (dst_fmt_q2)
      fpnew_pkg::FP64:    exp_max_dst = SUPER_EXP_BITS'(2047);
      fpnew_pkg::FP32:    exp_max_dst = SUPER_EXP_BITS'(255);
      fpnew_pkg::FP16ALT: exp_max_dst = SUPER_EXP_BITS'(255);
      fpnew_pkg::FP16:    exp_max_dst = SUPER_EXP_BITS'(31);
      fpnew_pkg::FP8:     exp_max_dst = SUPER_EXP_BITS'(31);
      default:            exp_max_dst = '1;
    endcase
  end
  // Classification before round. RISC-V mandates checking underflow AFTER rounding!
  assign of_before_round = final_exponent >= signed'({1'b0, exp_max_dst});
  assign uf_before_round = final_exponent == 0;               // exponent for subnormals capped to 0

  // Pack exponent and mantissa into proper rounding form
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_res_assemble
    // Set up some constants
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    logic [EXP_BITS-1:0] pre_round_exponent;
    logic [MAN_BITS-1:0] pre_round_mantissa;

    if (FpFmtConfig[fmt]) begin : active_format

      assign pre_round_exponent = (of_before_round) ? 2**EXP_BITS-2 : final_exponent[EXP_BITS-1:0];
      assign pre_round_mantissa = (of_before_round) ? '1 : final_mantissa[SUPER_MAN_BITS-:MAN_BITS];
      // Assemble result before rounding. In case of overflow, the largest normal value is set.
      assign fmt_pre_round_abs[fmt] = {pre_round_exponent, pre_round_mantissa}; // 0-extend

      // Round bit is after mantissa (1 in case of overflow for rounding)
      assign fmt_round_sticky_bits[fmt][1] = final_mantissa[SUPER_MAN_BITS-MAN_BITS] |
                                             of_before_round;

      // remaining bits in mantissa to sticky (1 in case of overflow for rounding)
      if (MAN_BITS < SUPER_MAN_BITS) begin : narrow_sticky
        assign fmt_round_sticky_bits[fmt][0] = (| final_mantissa[SUPER_MAN_BITS-MAN_BITS-1:0]) |
                                               sticky_after_norm | of_before_round;
      end else begin : normal_sticky
        assign fmt_round_sticky_bits[fmt][0] = sticky_after_norm | of_before_round;
      end
    end else begin : inactive_format
      assign fmt_pre_round_abs[fmt] = '{default: fpnew_pkg::DONT_CARE};
      assign fmt_round_sticky_bits[fmt] = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // Assemble result before rounding. In case of overflow, the largest normal value is set.
  assign pre_round_sign     = final_sign_q;
  assign pre_round_abs      = fmt_pre_round_abs[dst_fmt_q2];

  // In case of overflow, the round and sticky bits are set for proper rounding
  assign round_sticky_bits  = fmt_round_sticky_bits[dst_fmt_q2];

  // Perform the rounding
  fpnew_rounding #(
    .AbsWidth ( SUPER_EXP_BITS + SUPER_MAN_BITS )
  ) i_fpnew_rounding (
    .abs_value_i             ( pre_round_abs           ),
    .sign_i                  ( pre_round_sign          ),
    .round_sticky_bits_i     ( round_sticky_bits       ),
    .rnd_mode_i              ( rnd_mode_q              ),
    .effective_subtraction_i ( eff_n_q                  ),
    .abs_rounded_o           ( rounded_abs             ),
    .sign_o                  ( rounded_sign            ),
    .exact_zero_o            ( result_zero             )
  );

  logic [NUM_FORMATS-1:0][WIDTH-1:0] fmt_result;

  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_sign_inject
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (FpFmtConfig[fmt]) begin : active_format
      always_comb begin : post_process
        // detect of / uf
        fmt_uf_after_round[fmt] = (rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '0) // denormal
        || ((pre_round_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '0) && (rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == 1) &&
              ((round_sticky_bits != 2'b11) || (!sum_sticky_bits[MAN_BITS*2 + 4] && ((rnd_mode_q == fpnew_pkg::RNE) || (rnd_mode_q == fpnew_pkg::RMM)))));
        fmt_of_after_round[fmt] = rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '1; // inf exp.

        // Assemble regular result, nan box short ones.
        fmt_result[fmt]               = '1;
        fmt_result[fmt][FP_WIDTH-1:0] = {rounded_sign, rounded_abs[EXP_BITS+MAN_BITS-1:0]};
      end
    end else begin : inactive_format
      assign fmt_uf_after_round[fmt] = fpnew_pkg::DONT_CARE;
      assign fmt_of_after_round[fmt] = fpnew_pkg::DONT_CARE;
      assign fmt_result[fmt]         = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // Classification after rounding select by destination format
  assign uf_after_round = fmt_uf_after_round[dst_fmt_q2];
  assign of_after_round = fmt_of_after_round[dst_fmt_q2];


  // -----------------
  // Result selection
  // -----------------
  logic [WIDTH-1:0]     regular_result;
  fpnew_pkg::status_t   regular_status;

  // Assemble regular result
  assign regular_result = fmt_result[dst_fmt_q2];
  assign regular_status.NV = 1'b0; // only valid cases are handled in regular path
  assign regular_status.DZ = 1'b0; // no divisions
  assign regular_status.OF = of_before_round | of_after_round;   // rounding can introduce overflow
  assign regular_status.UF = uf_after_round & regular_status.NX; // only inexact results raise UF
  assign regular_status.NX = (| round_sticky_bits) | of_before_round | of_after_round;

  // Final results for output pipeline
  logic [WIDTH-1:0]   result_d;
  fpnew_pkg::status_t status_d;

  // Select output depending on special case detection
  assign result_d = result_is_special_q ? special_result_q : regular_result;
  assign status_d = result_is_special_q ? special_status_q : regular_status;

  // ----------------
  // Output Pipeline
  // ----------------
  // Output pipeline signals, index i holds signal after i register stages
  logic               [0:NUM_OUT_REGS][WIDTH-1:0] out_pipe_result_q;
  fpnew_pkg::status_t [0:NUM_OUT_REGS]            out_pipe_status_q;
  TagType             [0:NUM_OUT_REGS]            out_pipe_tag_q;
  logic               [0:NUM_OUT_REGS]            out_pipe_mask_q;
  AuxType             [0:NUM_OUT_REGS]            out_pipe_aux_q;
  logic               [0:NUM_OUT_REGS]            out_pipe_valid_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_OUT_REGS] out_pipe_ready;

  // Input stage: First element of pipeline is taken from inputs
  assign out_pipe_result_q[0] = result_d;
  assign out_pipe_status_q[0] = status_d;
  assign out_pipe_tag_q[0]    = tag_n_q;
  assign out_pipe_mask_q[0]   = mask_n_q;
  assign out_pipe_aux_q[0]    = aux_n_q;
  assign out_pipe_valid_q[0]  = norm_valid_q;
  // Ready backs up through the normalize register.
  assign mid_pipe_ready[NUM_MID_REGS] = norm_ready;
  // Generate the register stages
  for (genvar i = 0; i < NUM_OUT_REGS; i++) begin : gen_output_pipeline
    // Internal register enable for this stage
    logic reg_ena;
    // Determine the ready signal of the current stage - advance the pipeline:
    // 1. if the next stage is ready for our data
    // 2. if the next stage only holds a bubble (not valid) -> we can pop it
    assign out_pipe_ready[i] = out_pipe_ready[i+1] | ~out_pipe_valid_q[i+1];
    // Valid: enabled by ready signal, synchronous clear with the flush signal
    `FFLARNC(out_pipe_valid_q[i+1], out_pipe_valid_q[i], out_pipe_ready[i], flush_i, 1'b0, clk_i, rst_ni)
    // Enable register if pipleine ready and a valid data item is present
    assign reg_ena = (out_pipe_ready[i] & out_pipe_valid_q[i]) | reg_ena_i[NUM_INP_REGS + NUM_MID_REGS + i];
    // Generate the pipeline registers within the stages, use enable-registers
    `FFL(out_pipe_result_q[i+1], out_pipe_result_q[i], reg_ena, '0)
    `FFL(out_pipe_status_q[i+1], out_pipe_status_q[i], reg_ena, '0)
    `FFL(out_pipe_tag_q[i+1],    out_pipe_tag_q[i],    reg_ena, TagType'('0))
    `FFL(out_pipe_mask_q[i+1],   out_pipe_mask_q[i],   reg_ena, '0)
    `FFL(out_pipe_aux_q[i+1],    out_pipe_aux_q[i],    reg_ena, AuxType'('0))
  end
  // Output stage: Ready travels backwards from output side, driven by downstream circuitry
  assign out_pipe_ready[NUM_OUT_REGS] = out_ready_i;
  // Output stage: assign module outputs
  assign result_o        = out_pipe_result_q[NUM_OUT_REGS];
  assign status_o        = out_pipe_status_q[NUM_OUT_REGS];
  assign extension_bit_o = 1'b1; // always NaN-Box result
  assign tag_o           = out_pipe_tag_q[NUM_OUT_REGS];
  assign mask_o          = out_pipe_mask_q[NUM_OUT_REGS];
  assign aux_o           = out_pipe_aux_q[NUM_OUT_REGS];
  assign out_valid_o     = out_pipe_valid_q[NUM_OUT_REGS];
  assign busy_o          = (| {inp_pipe_valid_q, exp_valid_q, sum_valid_q, norm_valid_q, mid_pipe_valid_q, out_pipe_valid_q});

  // Early valid_o signal. This is used for dispatching instructions for dual-issue processor.
  if (NUM_OUT_REGS > 0) begin
    assign early_out_valid_o = |{out_pipe_valid_q[NUM_OUT_REGS] & ~out_pipe_ready[NUM_OUT_REGS],
                                 out_pipe_valid_q[NUM_OUT_REGS-1]};
  end else if (NUM_MID_REGS > 0) begin
    assign early_out_valid_o = |{mid_pipe_valid_q[NUM_MID_REGS] & ~mid_pipe_ready[NUM_OUT_REGS],
                                 mid_pipe_valid_q[NUM_MID_REGS-1]};
  end else if (NUM_INP_REGS > 0) begin
    assign early_out_valid_o = |{inp_pipe_valid_q[NUM_INP_REGS] & ~inp_pipe_ready[NUM_INP_REGS],
                                 inp_pipe_valid_q[NUM_INP_REGS-1]};
  end else begin
    assign early_out_valid_o = 1'b0;
  end

endmodule
