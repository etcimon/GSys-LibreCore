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

module fpnew_cast_multi #(
  parameter fpnew_pkg::fmt_logic_t   FpFmtConfig  = '1,
  parameter fpnew_pkg::ifmt_logic_t  IntFmtConfig = '1,
  // FPU configuration
  // hyp8: fpu_wrap passes these (LAT_CV=4, DISTRIBUTED). The
  // defaults match that instantiation so a module-as-top timing
  // run sees the same stages. Callers that pass both override them.
  parameter int unsigned             NumPipeRegs = 4,
  parameter fpnew_pkg::pipe_config_t PipeConfig  = fpnew_pkg::DISTRIBUTED,
  parameter type                     TagType     = logic,
  parameter type                     AuxType     = logic,
  // Do not change
  localparam int unsigned WIDTH = fpnew_pkg::maximum(fpnew_pkg::max_fp_width(FpFmtConfig),
                                                     fpnew_pkg::max_int_width(IntFmtConfig)),
  localparam int unsigned NUM_FORMATS = fpnew_pkg::NUM_FP_FORMATS,
  localparam int unsigned ExtRegEnaWidth = NumPipeRegs == 0 ? 1 : NumPipeRegs
) (
  input  logic                   clk_i,
  input  logic                   rst_ni,
  // Input signals
  input  logic [WIDTH-1:0]       operands_i, // 1 operand
  input  logic [NUM_FORMATS-1:0] is_boxed_i, // 1 operand
  input  fpnew_pkg::roundmode_e  rnd_mode_i,
  input  fpnew_pkg::operation_e  op_i,
  input  logic                   op_mod_i,
  input  fpnew_pkg::fp_format_e  src_fmt_i,
  input  fpnew_pkg::fp_format_e  dst_fmt_i,
  input  fpnew_pkg::int_format_e int_fmt_i,
  input  TagType                 tag_i,
  input  logic                   mask_i,
  input  AuxType                 aux_i,
  // Input Handshake
  input  logic                   in_valid_i,
  output logic                   in_ready_o,
  input  logic                   flush_i,
  // Output signals
  output logic [WIDTH-1:0]       result_o,
  output fpnew_pkg::status_t     status_o,
  output logic                   extension_bit_o,
  output TagType                 tag_o,
  output logic                   mask_o,
  output AuxType                 aux_o,
  // Output handshake
  output logic                   out_valid_o,
  input  logic                   out_ready_i,
  // Indication of valid data in flight
  output logic                   busy_o,
  // External register enable override
  input  logic [ExtRegEnaWidth-1:0] reg_ena_i,
  // Early valid for external structural hazard generation
  output logic                   early_out_valid_o
);

  // ----------
  // Constants
  // ----------
  localparam int unsigned NUM_INT_FORMATS = fpnew_pkg::NUM_INT_FORMATS;
  localparam int unsigned MAX_INT_WIDTH   = fpnew_pkg::max_int_width(IntFmtConfig);

  localparam fpnew_pkg::fp_encoding_t SUPER_FORMAT = fpnew_pkg::super_format(FpFmtConfig);

  localparam int unsigned SUPER_EXP_BITS = SUPER_FORMAT.exp_bits;
  localparam int unsigned SUPER_MAN_BITS = SUPER_FORMAT.man_bits;
  localparam int unsigned SUPER_BIAS     = 2**(SUPER_EXP_BITS - 1) - 1;

  // The internal mantissa includes normal bit or an entire integer
  localparam int unsigned INT_MAN_WIDTH = fpnew_pkg::maximum(SUPER_MAN_BITS + 1, MAX_INT_WIDTH);
  // If needed, there will be a LZC for renormalization
  localparam int unsigned LZC_RESULT_WIDTH = $clog2(INT_MAN_WIDTH);
  // The internal exponent must be able to represent the smallest denormal input value as signed
  // or the number of bits in an integer
  localparam int unsigned INT_EXP_WIDTH = fpnew_pkg::maximum($clog2(MAX_INT_WIDTH),
      fpnew_pkg::maximum(SUPER_EXP_BITS, $clog2(SUPER_BIAS + SUPER_MAN_BITS))) + 1;
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

  // ---------------
  // Input pipeline
  // ---------------
  // Selected pipeline output signals as non-arrays
  logic [WIDTH-1:0]       operands_q;
  logic [NUM_FORMATS-1:0] is_boxed_q;
  logic                   op_mod_q;
  fpnew_pkg::fp_format_e  src_fmt_q;
  fpnew_pkg::fp_format_e  dst_fmt_q;
  fpnew_pkg::int_format_e int_fmt_q;

  // Input pipeline signals, index i holds signal after i register stages
  logic                   [0:NUM_INP_REGS][WIDTH-1:0]       inp_pipe_operands_q;
  logic                   [0:NUM_INP_REGS][NUM_FORMATS-1:0] inp_pipe_is_boxed_q;
  fpnew_pkg::roundmode_e  [0:NUM_INP_REGS]                  inp_pipe_rnd_mode_q;
  fpnew_pkg::operation_e  [0:NUM_INP_REGS]                  inp_pipe_op_q;
  logic                   [0:NUM_INP_REGS]                  inp_pipe_op_mod_q;
  fpnew_pkg::fp_format_e  [0:NUM_INP_REGS]                  inp_pipe_src_fmt_q;
  fpnew_pkg::fp_format_e  [0:NUM_INP_REGS]                  inp_pipe_dst_fmt_q;
  fpnew_pkg::int_format_e [0:NUM_INP_REGS]                  inp_pipe_int_fmt_q;
  TagType                 [0:NUM_INP_REGS]                  inp_pipe_tag_q;
  logic                   [0:NUM_INP_REGS]                  inp_pipe_mask_q;
  AuxType                 [0:NUM_INP_REGS]                  inp_pipe_aux_q;
  logic                   [0:NUM_INP_REGS]                  inp_pipe_valid_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_INP_REGS] inp_pipe_ready;

  // Input stage: First element of pipeline is taken from inputs
  assign inp_pipe_operands_q[0] = operands_i;
  assign inp_pipe_is_boxed_q[0] = is_boxed_i;
  assign inp_pipe_rnd_mode_q[0] = rnd_mode_i;
  assign inp_pipe_op_q[0]       = op_i;
  assign inp_pipe_op_mod_q[0]   = op_mod_i;
  assign inp_pipe_src_fmt_q[0]  = src_fmt_i;
  assign inp_pipe_dst_fmt_q[0]  = dst_fmt_i;
  assign inp_pipe_int_fmt_q[0]  = int_fmt_i;
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
    `FFL(inp_pipe_dst_fmt_q[i+1],  inp_pipe_dst_fmt_q[i],  reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(inp_pipe_int_fmt_q[i+1],  inp_pipe_int_fmt_q[i],  reg_ena, fpnew_pkg::int_format_e'(0))
    `FFL(inp_pipe_tag_q[i+1],      inp_pipe_tag_q[i],      reg_ena, TagType'('0))
    `FFL(inp_pipe_mask_q[i+1],     inp_pipe_mask_q[i],     reg_ena, '0)
    `FFL(inp_pipe_aux_q[i+1],      inp_pipe_aux_q[i],      reg_ena, AuxType'('0))
  end
  // Output stage: assign selected pipe outputs to signals for later use
  assign operands_q = inp_pipe_operands_q[NUM_INP_REGS];
  assign is_boxed_q = inp_pipe_is_boxed_q[NUM_INP_REGS];
  assign op_mod_q   = inp_pipe_op_mod_q[NUM_INP_REGS];
  assign src_fmt_q  = inp_pipe_src_fmt_q[NUM_INP_REGS];
  assign dst_fmt_q  = inp_pipe_dst_fmt_q[NUM_INP_REGS];
  assign int_fmt_q  = inp_pipe_int_fmt_q[NUM_INP_REGS];

  // -----------------
  // Input processing
  // -----------------
  logic src_is_int, dst_is_int; // if 0, it's a float

  assign src_is_int = (inp_pipe_op_q[NUM_INP_REGS] == fpnew_pkg::I2F);
  assign dst_is_int = (inp_pipe_op_q[NUM_INP_REGS] == fpnew_pkg::F2I);

  logic [INT_MAN_WIDTH-1:0] encoded_mant; // input mantissa with implicit bit

  logic        [NUM_FORMATS-1:0]                    fmt_sign;
  logic signed [NUM_FORMATS-1:0][INT_EXP_WIDTH-1:0] fmt_exponent;
  logic        [NUM_FORMATS-1:0][INT_MAN_WIDTH-1:0] fmt_mantissa;
  logic signed [NUM_FORMATS-1:0][INT_EXP_WIDTH-1:0] fmt_shift_compensation; // for LZC

  fpnew_pkg::fp_info_t [NUM_FORMATS-1:0] info;

  logic [NUM_INT_FORMATS-1:0][INT_MAN_WIDTH-1:0] ifmt_input_val;
  logic                                          int_sign;
  logic [INT_MAN_WIDTH-1:0]                      int_value, int_mantissa;

  // FP Input initialization
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : fmt_init_inputs
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (FpFmtConfig[fmt]) begin : active_format
      localparam fpnew_pkg::fp_format_e FpFormat = fpnew_pkg::fp_format_e'(fmt);

      // Classify input
      fpnew_classifier #(
        .FpFormat    ( FpFormat ),
        .NumOperands ( 1        )
      ) i_fpnew_classifier (
        .operands_i ( operands_q[FP_WIDTH-1:0] ),
        .is_boxed_i ( is_boxed_q[fmt]          ),
        .info_o     ( info[fmt]                )
      );

      assign fmt_sign[fmt]     = operands_q[FP_WIDTH-1];
      assign fmt_exponent[fmt] = signed'({1'b0, operands_q[MAN_BITS+:EXP_BITS]});
      assign fmt_mantissa[fmt] = {info[fmt].is_normal, operands_q[MAN_BITS-1:0]}; // zero pad
      // Compensation for the difference in mantissa widths used for leading-zero count
      assign fmt_shift_compensation[fmt] = signed'(INT_MAN_WIDTH - 1 - MAN_BITS);
    end else begin : inactive_format
      assign info[fmt]                   = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_sign[fmt]               = fpnew_pkg::DONT_CARE;             // format disabled
      assign fmt_exponent[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_mantissa[fmt]           = '{default: fpnew_pkg::DONT_CARE}; // format disabled
      assign fmt_shift_compensation[fmt] = '{default: fpnew_pkg::DONT_CARE}; // format disabled
    end
  end

  // Sign-extend INT input
  for (genvar ifmt = 0; ifmt < int'(NUM_INT_FORMATS); ifmt++) begin : gen_sign_extend_int
    // Set up some constants
    localparam int unsigned INT_WIDTH = fpnew_pkg::int_width(fpnew_pkg::int_format_e'(ifmt));

    if (IntFmtConfig[ifmt]) begin : active_format // only active formats
      always_comb begin : sign_ext_input
        // sign-extend value only if it's signed
        ifmt_input_val[ifmt]                = '{default: operands_q[INT_WIDTH-1] & ~op_mod_q};
        ifmt_input_val[ifmt][INT_WIDTH-1:0] = operands_q[INT_WIDTH-1:0];
      end
    end else begin : inactive_format
      assign ifmt_input_val[ifmt] = '{default: fpnew_pkg::DONT_CARE}; // format disabled
    end
  end

  // Construct input mantissa from integer. The sign-extend and the
  // format mux land in p_int_cap; the 64-bit magnitude negate is the
  // next cycle, with the LZC. out_valid moves with p_int_cap.
  assign int_value    = ifmt_input_val[int_fmt_q];
  assign int_sign     = int_value[INT_MAN_WIDTH-1] & ~op_mod_q; // only signed ints are negative
  assign int_mantissa = int_sign_m ? unsigned'(-int_value_m) : int_value_m;

  // select mantissa with source format
  assign encoded_mant = src_is_int_m ? int_mantissa : fp_mant_m;

  // --------------
  // Normalization
  // --------------
  logic signed [INT_EXP_WIDTH-1:0] src_bias;      // src format bias
  logic signed [INT_EXP_WIDTH-1:0] src_exp;       // src format exponent (biased)
  logic signed [INT_EXP_WIDTH-1:0] src_subnormal; // src is subnormal
  logic signed [INT_EXP_WIDTH-1:0] src_offset;    // src offset within mantissa

  // IEEE bias and the all-ones exponent are constants per format.
  // fpnew_pkg::bias is 2**(exp_bits-1)-1; a variable power is a barrel.
  function automatic logic signed [INT_EXP_WIDTH-1:0] cast_bias(
      input fpnew_pkg::fp_format_e fmt);
    unique case (fmt)
      fpnew_pkg::FP32:    return INT_EXP_WIDTH'(127);
      fpnew_pkg::FP64:    return INT_EXP_WIDTH'(1023);
      fpnew_pkg::FP16:    return INT_EXP_WIDTH'(15);
      fpnew_pkg::FP8:     return INT_EXP_WIDTH'(15);
      fpnew_pkg::FP16ALT: return INT_EXP_WIDTH'(127);
      default:            return '0;
    endcase
  endfunction
  function automatic logic [INT_EXP_WIDTH-1:0] cast_exp_max(
      input fpnew_pkg::fp_format_e fmt);
    unique case (fmt)
      fpnew_pkg::FP32:    return INT_EXP_WIDTH'(255);
      fpnew_pkg::FP64:    return INT_EXP_WIDTH'(2047);
      fpnew_pkg::FP16:    return INT_EXP_WIDTH'(31);
      fpnew_pkg::FP8:     return INT_EXP_WIDTH'(31);
      fpnew_pkg::FP16ALT: return INT_EXP_WIDTH'(255);
      default:            return '0;
    endcase
  endfunction
  function automatic logic [7:0] cast_man(
      input fpnew_pkg::fp_format_e fmt);
    unique case (fmt)
      fpnew_pkg::FP32:    return 8'd23;
      fpnew_pkg::FP64:    return 8'd52;
      fpnew_pkg::FP16:    return 8'd10;
      fpnew_pkg::FP8:     return 8'd2;
      fpnew_pkg::FP16ALT: return 8'd7;
      default:            return '0;
    endcase
  endfunction
  // fpnew_pkg::int_width returns a 32-bit int. The overflow compare
  // only needs the four widths, and 64 fits in the internal exponent.
  function automatic logic signed [INT_EXP_WIDTH-1:0] cast_int_w(
      input fpnew_pkg::int_format_e ifmt);
    unique case (ifmt)
      fpnew_pkg::INT8:  return INT_EXP_WIDTH'(8);
      fpnew_pkg::INT16: return INT_EXP_WIDTH'(16);
      fpnew_pkg::INT32: return INT_EXP_WIDTH'(32);
      fpnew_pkg::INT64: return INT_EXP_WIDTH'(64);
      default:          return '0;
    endcase
  endfunction

  assign src_bias      = cast_bias(src_fmt_q);
  assign src_exp       = fmt_exponent[src_fmt_q];
  assign src_subnormal = signed'({1'b0, info[src_fmt_q].is_subnormal});
  assign src_offset    = fmt_shift_compensation[src_fmt_q];

  logic                            input_sign;   // input sign
  logic signed [INT_EXP_WIDTH-1:0] input_exp;    // unbiased true exponent
  logic        [INT_MAN_WIDTH-1:0] input_mant;   // normalized input mantissa
  logic                            mant_is_zero; // for integer zeroes

  logic signed [INT_EXP_WIDTH-1:0] fp_input_exp;
  logic signed [INT_EXP_WIDTH-1:0] int_input_exp;

  // Input mantissa needs to be normalized
  logic [LZC_RESULT_WIDTH-1:0] renorm_shamt;     // renormalization shift amount

  // Leading-zero counter is needed for renormalization
  lzc #(
    .WIDTH ( INT_MAN_WIDTH ),
    .MODE  ( 1             ) // MODE = 1 counts leading zeroes
  ) i_lzc (
    .in_i    ( encoded_mant ),
    .cnt_o   ( renorm_shamt ),
    .empty_o ( mant_is_zero )
  );
  // Get the sign from the proper source
  assign input_sign = src_is_int_m ? int_sign_m : fp_sign_m;
  // Format-only partial of the unbiased exponent. The LZC term is
  // subtracted after p_renorm, in the cycle the mid pipe already
  // uses for the mantissa shift. Same width, so the split wraps
  // like the original single sum. No extra valid stage.
  logic signed [INT_EXP_WIDTH-1:0] exp_noshamt;
  logic signed [INT_EXP_WIDTH-1:0] dst_bias;
  assign exp_noshamt = signed'(src_exp + src_subnormal - src_bias + src_offset);
  assign dst_bias    = cast_bias(dst_fmt_q);

  logic signed [INT_EXP_WIDTH-1:0] destination_exp;  // re-biased exponent for destination

  // ---------------
  // Internal pipeline
  // ---------------
  // Pipeline output signals as non-arrays
  logic                            input_sign_q;
  logic signed [INT_EXP_WIDTH-1:0] input_exp_q;
  logic [INT_MAN_WIDTH-1:0]        input_mant_q;
  logic signed [INT_EXP_WIDTH-1:0] destination_exp_q;
  logic                            src_is_int_q;
  logic                            dst_is_int_q;
  fpnew_pkg::fp_info_t             info_q;
  logic                            mant_is_zero_q;
  logic                            op_mod_q2;
  fpnew_pkg::roundmode_e           rnd_mode_q;
  fpnew_pkg::fp_format_e           src_fmt_q2;
  fpnew_pkg::fp_format_e           dst_fmt_q2;
  fpnew_pkg::int_format_e          int_fmt_q2;
  // Internal pipeline signals, index i holds signal after i register stages


  logic                   [0:NUM_MID_REGS]                    mid_pipe_input_sign_q;
  logic signed            [0:NUM_MID_REGS][INT_EXP_WIDTH-1:0] mid_pipe_input_exp_q;
  logic                   [0:NUM_MID_REGS][INT_MAN_WIDTH-1:0] mid_pipe_input_mant_q;
  logic signed            [0:NUM_MID_REGS][INT_EXP_WIDTH-1:0] mid_pipe_dest_exp_q;
  logic                   [0:NUM_MID_REGS]                    mid_pipe_src_is_int_q;
  logic                   [0:NUM_MID_REGS]                    mid_pipe_dst_is_int_q;
  fpnew_pkg::fp_info_t    [0:NUM_MID_REGS]                    mid_pipe_info_q;
  logic                   [0:NUM_MID_REGS]                    mid_pipe_mant_zero_q;
  logic                   [0:NUM_MID_REGS]                    mid_pipe_op_mod_q;
  fpnew_pkg::roundmode_e  [0:NUM_MID_REGS]                    mid_pipe_rnd_mode_q;
  fpnew_pkg::fp_format_e  [0:NUM_MID_REGS]                    mid_pipe_src_fmt_q;
  fpnew_pkg::fp_format_e  [0:NUM_MID_REGS]                    mid_pipe_dst_fmt_q;
  fpnew_pkg::int_format_e [0:NUM_MID_REGS]                    mid_pipe_int_fmt_q;
  TagType                 [0:NUM_MID_REGS]                    mid_pipe_tag_q;
  logic                   [0:NUM_MID_REGS]                    mid_pipe_mask_q;
  AuxType                 [0:NUM_MID_REGS]                    mid_pipe_aux_q;
  logic                   [0:NUM_MID_REGS]                    mid_pipe_valid_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_MID_REGS] mid_pipe_ready;

  // Leading-zero count and the format partial land here. The LZC
  // subtract and the rebias are the next cycle, captured by
  // p_exp_align. The generated mid-pipe registers are not a measured
  // cut, so this explicit stage is what keeps that add off the
  // denorm cone. out_valid moves with it. FP_LAT counts it.
  logic                            renorm_ready, renorm_valid_q, renorm_ena;
  logic [INT_MAN_WIDTH-1:0]        encoded_mant_q;
  logic [LZC_RESULT_WIDTH-1:0]     renorm_shamt_q;
  logic                            input_sign_h;
  logic signed [INT_EXP_WIDTH-1:0] exp_noshamt_q, dst_bias_q;
  logic                            src_is_int_h, dst_is_int_h, mant_is_zero_h, op_mod_h;
  fpnew_pkg::fp_info_t             info_h;
  fpnew_pkg::roundmode_e           rnd_mode_h;
  fpnew_pkg::fp_format_e           src_fmt_h, dst_fmt_h;
  fpnew_pkg::int_format_e          int_fmt_h;
  TagType                          tag_h;
  logic                            mask_h;
  AuxType                          aux_h;

  logic                            align_ready, align_valid_q, align_ena;
  logic                            int_ready, int_valid_q, int_ena;
  logic [INT_MAN_WIDTH-1:0]        int_value_m, fp_mant_m;
  logic                            int_sign_m, fp_sign_m, src_is_int_m;
  logic signed [INT_EXP_WIDTH-1:0] exp_noshamt_m, dst_bias_m;
  logic                            dst_is_int_m, op_mod_m, mask_m;
  fpnew_pkg::fp_info_t             info_m;
  fpnew_pkg::roundmode_e           rnd_mode_m;
  fpnew_pkg::fp_format_e           src_fmt_m, dst_fmt_m;
  fpnew_pkg::int_format_e          int_fmt_m;
  TagType                          tag_m;
  AuxType                          aux_m;

  assign align_ready = mid_pipe_ready[0] | ~align_valid_q;
  assign align_ena   = align_ready & renorm_valid_q;
  assign renorm_ready = align_ready | ~renorm_valid_q;
  assign int_ready  = renorm_ready | ~int_valid_q;
  assign int_ena    = int_ready & inp_pipe_valid_q[NUM_INP_REGS];
  assign renorm_ena = renorm_ready & int_valid_q;

  // Magnitude negate reads these. Controls captured with the same
  // enable so the next instruction cannot pair with this mantissa.
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_int_valid
    if (!rst_ni) int_valid_q <= 1'b0;
    else if (flush_i) int_valid_q <= 1'b0;
    else if (int_ready) int_valid_q <= inp_pipe_valid_q[NUM_INP_REGS];
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_int_val
    if (!rst_ni) begin
      int_value_m <= '0;
      int_sign_m  <= 1'b0;
    end else if (int_ena) begin
      int_value_m <= int_value;
      int_sign_m  <= int_sign;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_int_fm
    if (!rst_ni) begin
      fp_mant_m    <= '0;
      fp_sign_m    <= 1'b0;
      src_is_int_m <= 1'b0;
    end else if (int_ena) begin
      fp_mant_m    <= fmt_mantissa[src_fmt_q];
      fp_sign_m    <= fmt_sign[src_fmt_q];
      src_is_int_m <= src_is_int;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_int_noshamt
    if (!rst_ni) exp_noshamt_m <= '0;
    else if (int_ena) exp_noshamt_m <= exp_noshamt;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_int_dstbias
    if (!rst_ni) dst_bias_m <= '0;
    else if (int_ena) dst_bias_m <= dst_bias;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_int_ctrl
    if (!rst_ni) begin
      dst_is_int_m <= 1'b0;
      op_mod_m     <= 1'b0;
      info_m       <= '0;
      rnd_mode_m   <= fpnew_pkg::RNE;
      src_fmt_m    <= fpnew_pkg::fp_format_e'(0);
      dst_fmt_m    <= fpnew_pkg::fp_format_e'(0);
      int_fmt_m    <= fpnew_pkg::int_format_e'(0);
      tag_m        <= TagType'('0);
      mask_m       <= 1'b0;
      aux_m        <= AuxType'('0);
    end else if (int_ena) begin
      dst_is_int_m <= dst_is_int;
      op_mod_m     <= op_mod_q;
      info_m       <= info[src_fmt_q];
      rnd_mode_m   <= inp_pipe_rnd_mode_q[NUM_INP_REGS];
      src_fmt_m    <= src_fmt_q;
      dst_fmt_m    <= dst_fmt_q;
      int_fmt_m    <= int_fmt_q;
      tag_m        <= inp_pipe_tag_q[NUM_INP_REGS];
      mask_m       <= inp_pipe_mask_q[NUM_INP_REGS];
      aux_m        <= inp_pipe_aux_q[NUM_INP_REGS];
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_renorm_valid
    if (!rst_ni) renorm_valid_q <= 1'b0;
    else if (flush_i) renorm_valid_q <= 1'b0;
    else if (renorm_ready) renorm_valid_q <= int_valid_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_renorm_mant
    if (!rst_ni) begin
      encoded_mant_q <= '0;
      renorm_shamt_q <= '0;
    end else if (renorm_ena) begin
      encoded_mant_q <= encoded_mant;
      renorm_shamt_q <= renorm_shamt;
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_renorm_exp
    if (!rst_ni) begin
      input_sign_h      <= 1'b0;
      src_is_int_h      <= 1'b0;
      dst_is_int_h      <= 1'b0;
      mant_is_zero_h    <= 1'b0;
      op_mod_h          <= 1'b0;
      info_h            <= '0;
      rnd_mode_h        <= fpnew_pkg::RNE;
      src_fmt_h         <= fpnew_pkg::fp_format_e'(0);
      dst_fmt_h         <= fpnew_pkg::fp_format_e'(0);
      int_fmt_h         <= fpnew_pkg::int_format_e'(0);
      tag_h             <= TagType'('0);
      mask_h            <= 1'b0;
      aux_h             <= AuxType'('0);
    end else if (renorm_ena) begin
      input_sign_h      <= input_sign;
      src_is_int_h      <= src_is_int_m;
      dst_is_int_h      <= dst_is_int_m;
      mant_is_zero_h    <= mant_is_zero;
      op_mod_h          <= op_mod_m;
      info_h            <= info_m;
      rnd_mode_h        <= rnd_mode_m;
      src_fmt_h         <= src_fmt_m;
      dst_fmt_h         <= dst_fmt_m;
      int_fmt_h         <= int_fmt_m;
      tag_h             <= tag_m;
      mask_h            <= mask_m;
      aux_h             <= aux_m;
    end
  end
  // Own processes so statement order cannot glue the partial sum
  // onto the bias mux. Same enable as the mantissa capture.
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_renorm_noshamt
    if (!rst_ni) exp_noshamt_q <= '0;
    else if (renorm_ena) exp_noshamt_q <= exp_noshamt_m;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_renorm_dstbias
    if (!rst_ni) dst_bias_q <= '0;
    else if (renorm_ena) dst_bias_q <= dst_bias_m;
  end

  // Variable align, from the registered LZC result.
  assign input_mant = encoded_mant_q << renorm_shamt_q;
  // Finish the exponent from the registered partial and the registered
  // shift. p_exp_align samples this with the shifted mantissa.
  assign fp_input_exp  = signed'(exp_noshamt_q - signed'({1'b0, renorm_shamt_q}));
  assign int_input_exp = signed'(INT_MAN_WIDTH - 1 - signed'({1'b0, renorm_shamt_q}));
  assign input_exp     = src_is_int_h ? int_input_exp : fp_input_exp;
  assign destination_exp = signed'(input_exp + dst_bias_q);

  // Explicit cut the timing tool can see. Separate processes so the
  // rebias cone is not statement-ordered onto the control bundle.
  logic                            input_sign_a, src_is_int_a, dst_is_int_a;
  logic                            mant_is_zero_a, op_mod_a, mask_a;
  logic signed [INT_EXP_WIDTH-1:0] input_exp_a, destination_exp_a;
  logic [INT_MAN_WIDTH-1:0]        input_mant_a;
  fpnew_pkg::fp_info_t             info_a;
  fpnew_pkg::roundmode_e           rnd_mode_a;
  fpnew_pkg::fp_format_e           src_fmt_a, dst_fmt_a;
  fpnew_pkg::int_format_e          int_fmt_a;
  TagType                          tag_a;
  AuxType                          aux_a;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_align_valid
    if (!rst_ni) align_valid_q <= 1'b0;
    else if (flush_i) align_valid_q <= 1'b0;
    else if (align_ready) align_valid_q <= renorm_valid_q;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_align_iexp
    if (!rst_ni) input_exp_a <= '0;
    else if (align_ena) input_exp_a <= input_exp;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_align_dexp
    if (!rst_ni) destination_exp_a <= '0;
    else if (align_ena) destination_exp_a <= destination_exp;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_align_mant
    if (!rst_ni) input_mant_a <= '0;
    else if (align_ena) input_mant_a <= input_mant;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_align_ctrl
    if (!rst_ni) begin
      input_sign_a   <= 1'b0;
      src_is_int_a   <= 1'b0;
      dst_is_int_a   <= 1'b0;
      mant_is_zero_a <= 1'b0;
      op_mod_a       <= 1'b0;
      info_a         <= '0;
      rnd_mode_a     <= fpnew_pkg::RNE;
      src_fmt_a      <= fpnew_pkg::fp_format_e'(0);
      dst_fmt_a      <= fpnew_pkg::fp_format_e'(0);
      int_fmt_a      <= fpnew_pkg::int_format_e'(0);
      tag_a          <= TagType'('0);
      mask_a         <= 1'b0;
      aux_a          <= AuxType'('0);
    end else if (align_ena) begin
      input_sign_a   <= input_sign_h;
      src_is_int_a   <= src_is_int_h;
      dst_is_int_a   <= dst_is_int_h;
      mant_is_zero_a <= mant_is_zero_h;
      op_mod_a       <= op_mod_h;
      info_a         <= info_h;
      rnd_mode_a     <= rnd_mode_h;
      src_fmt_a      <= src_fmt_h;
      dst_fmt_a      <= dst_fmt_h;
      int_fmt_a      <= int_fmt_h;
      tag_a          <= tag_h;
      mask_a         <= mask_h;
      aux_a          <= aux_h;
    end
  end

  // Input stage: first mid element is the aligned normalize result.
  assign mid_pipe_input_sign_q[0] = input_sign_a;
  assign mid_pipe_input_exp_q[0]  = input_exp_a;
  assign mid_pipe_input_mant_q[0] = input_mant_a;
  assign mid_pipe_dest_exp_q[0]   = destination_exp_a;
  assign mid_pipe_src_is_int_q[0] = src_is_int_a;
  assign mid_pipe_dst_is_int_q[0] = dst_is_int_a;
  assign mid_pipe_info_q[0]       = info_a;
  assign mid_pipe_mant_zero_q[0]  = mant_is_zero_a;
  assign mid_pipe_op_mod_q[0]     = op_mod_a;
  assign mid_pipe_rnd_mode_q[0]   = rnd_mode_a;
  assign mid_pipe_src_fmt_q[0]    = src_fmt_a;
  assign mid_pipe_dst_fmt_q[0]    = dst_fmt_a;
  assign mid_pipe_int_fmt_q[0]    = int_fmt_a;
  assign mid_pipe_tag_q[0]        = tag_a;
  assign mid_pipe_mask_q[0]       = mask_a;
  assign mid_pipe_aux_q[0]        = aux_a;
  assign mid_pipe_valid_q[0]      = align_valid_q;
  assign inp_pipe_ready[NUM_INP_REGS] = int_ready;

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
    `FFL(mid_pipe_input_sign_q[i+1], mid_pipe_input_sign_q[i], reg_ena, '0)
    `FFL(mid_pipe_input_exp_q[i+1],  mid_pipe_input_exp_q[i],  reg_ena, '0)
    `FFL(mid_pipe_input_mant_q[i+1], mid_pipe_input_mant_q[i], reg_ena, '0)
    `FFL(mid_pipe_dest_exp_q[i+1],   mid_pipe_dest_exp_q[i],   reg_ena, '0)
    `FFL(mid_pipe_src_is_int_q[i+1], mid_pipe_src_is_int_q[i], reg_ena, '0)
    `FFL(mid_pipe_dst_is_int_q[i+1], mid_pipe_dst_is_int_q[i], reg_ena, '0)
    `FFL(mid_pipe_info_q[i+1],       mid_pipe_info_q[i],       reg_ena, '0)
    `FFL(mid_pipe_mant_zero_q[i+1],  mid_pipe_mant_zero_q[i],  reg_ena, '0)
    `FFL(mid_pipe_op_mod_q[i+1],     mid_pipe_op_mod_q[i],     reg_ena, '0)
    `FFL(mid_pipe_rnd_mode_q[i+1],   mid_pipe_rnd_mode_q[i],   reg_ena, fpnew_pkg::RNE)
    `FFL(mid_pipe_src_fmt_q[i+1],    mid_pipe_src_fmt_q[i],    reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(mid_pipe_dst_fmt_q[i+1],    mid_pipe_dst_fmt_q[i],    reg_ena, fpnew_pkg::fp_format_e'(0))
    `FFL(mid_pipe_int_fmt_q[i+1],    mid_pipe_int_fmt_q[i],    reg_ena, fpnew_pkg::int_format_e'(0))
    `FFL(mid_pipe_tag_q[i+1],        mid_pipe_tag_q[i],        reg_ena, TagType'('0))
    `FFL(mid_pipe_mask_q[i+1],       mid_pipe_mask_q[i],       reg_ena, '0)
    `FFL(mid_pipe_aux_q[i+1],        mid_pipe_aux_q[i],        reg_ena, AuxType'('0))
  end
  // Pre-shift view of the mid-pipe outputs. cast_value reads these.
  // The names without _pre are captured by p_cast_shift with the
  // preshift mantissa, so rounding sees the same instruction as the
  // barrel. fpu_wrap's out_valid follows that capture.
  logic                            input_sign_pre;
  logic signed [INT_EXP_WIDTH-1:0] input_exp_pre;
  logic                            src_is_int_pre;
  logic                            dst_is_int_pre;
  fpnew_pkg::fp_info_t             info_pre;
  logic                            mant_is_zero_pre;
  logic                            op_mod_pre;
  fpnew_pkg::roundmode_e           rnd_mode_pre;
  fpnew_pkg::fp_format_e           dst_fmt_pre;
  fpnew_pkg::int_format_e          int_fmt_pre;

  assign input_sign_pre    = mid_pipe_input_sign_q[NUM_MID_REGS];
  assign input_exp_pre     = mid_pipe_input_exp_q[NUM_MID_REGS];
  assign input_mant_q      = mid_pipe_input_mant_q[NUM_MID_REGS];
  assign destination_exp_q = mid_pipe_dest_exp_q[NUM_MID_REGS];
  assign src_is_int_pre    = mid_pipe_src_is_int_q[NUM_MID_REGS];
  assign dst_is_int_pre    = mid_pipe_dst_is_int_q[NUM_MID_REGS];
  assign info_pre          = mid_pipe_info_q[NUM_MID_REGS];
  assign mant_is_zero_pre  = mid_pipe_mant_zero_q[NUM_MID_REGS];
  assign op_mod_pre        = mid_pipe_op_mod_q[NUM_MID_REGS];
  assign rnd_mode_pre      = mid_pipe_rnd_mode_q[NUM_MID_REGS];
  assign src_fmt_q2        = mid_pipe_src_fmt_q[NUM_MID_REGS];
  assign dst_fmt_pre       = mid_pipe_dst_fmt_q[NUM_MID_REGS];
  assign int_fmt_pre       = mid_pipe_int_fmt_q[NUM_MID_REGS];

  // --------
  // Casting
  // --------
  logic [INT_EXP_WIDTH-1:0] final_exp;        // after eventual adjustments

  logic [2*INT_MAN_WIDTH:0]  preshift_mant;    // mantissa before final shift
  logic [2*INT_MAN_WIDTH:0]  destination_mant; // mantissa from shifter, with rnd bit
  logic [SUPER_MAN_BITS-1:0] final_mant;       // mantissa after adjustments
  logic [MAX_INT_WIDTH-1:0]  final_int;        // integer shifted in position

  logic [$clog2(INT_MAN_WIDTH+1)-1:0] denorm_shamt; // shift amount for denormalization

  logic [1:0] fp_round_sticky_bits, int_round_sticky_bits, round_sticky_bits;
  logic       of_before_round, uf_before_round;
  // Inf clears the mantissa, overflow fills it. Kept out of the
  // mantissa wiring so the renorm shift is not a predecessor of the
  // exponent adjust.
  logic       preshift_zero, preshift_ones;


  // Exclusive arms, each a continuous assign. The old priority
  // if/else billed every arm in front of the last one.
  logic signed [INT_EXP_WIDTH-1:0] exp_max_s;
  logic [7:0]                      man_dst;
  logic                            int_ovf, int_uf, int_uf_exp;
  logic                            raw_inf, raw_ovf, raw_den, raw_stk;
  logic                            oh_inf, oh_ovf, oh_den, oh_stk;
  logic [$clog2(INT_MAN_WIDTH+1)-1:0] shamt_base, shamt_int, shamt_den, shamt_stk;

  assign exp_max_s = signed'(cast_exp_max(dst_fmt_pre));
  assign man_dst   = cast_man(dst_fmt_pre);
  // op_mod 0 is signed (threshold W-1); 1 is unsigned (threshold W).
  // Signed -2^(W-1) is in range, so that exact exponent is not overflow.
  // Each width is a constant compare. The format bits only select.
  logic signed [INT_EXP_WIDTH-1:0] thr8, thr16, thr32, thr64;
  logic edge8, edge16, edge32, edge64;
  logic ovf8, ovf16, ovf32, ovf64, int_ovf_fmt;
  assign thr8  = op_mod_pre ? INT_EXP_WIDTH'(8)  : INT_EXP_WIDTH'(7);
  assign thr16 = op_mod_pre ? INT_EXP_WIDTH'(16) : INT_EXP_WIDTH'(15);
  assign thr32 = op_mod_pre ? INT_EXP_WIDTH'(32) : INT_EXP_WIDTH'(31);
  assign thr64 = op_mod_pre ? INT_EXP_WIDTH'(64) : INT_EXP_WIDTH'(63);
  assign edge8  = !op_mod_pre && input_sign_pre && (input_exp_pre == INT_EXP_WIDTH'(7));
  assign edge16 = !op_mod_pre && input_sign_pre && (input_exp_pre == INT_EXP_WIDTH'(15));
  assign edge32 = !op_mod_pre && input_sign_pre && (input_exp_pre == INT_EXP_WIDTH'(31));
  assign edge64 = !op_mod_pre && input_sign_pre && (input_exp_pre == INT_EXP_WIDTH'(63));
  assign ovf8  = (input_exp_pre >= thr8)  && !edge8;
  assign ovf16 = (input_exp_pre >= thr16) && !edge16;
  assign ovf32 = (input_exp_pre >= thr32) && !edge32;
  assign ovf64 = (input_exp_pre >= thr64) && !edge64;
  // int_format_e is {INT64, INT32, INT16, INT8} = 2'b11 .. 2'b00.
  assign int_ovf_fmt = int_fmt_pre[1]
      ? (int_fmt_pre[0] ? ovf64 : ovf32)
      : (int_fmt_pre[0] ? ovf16 : ovf8);
  assign int_ovf = dst_is_int_pre && int_ovf_fmt;
  // Underflow's exponent test does not read int_ovf. The flag still
  // excludes overflow. The shift mux tests overflow first, so using the
  // exponent test there selects the same amount.
  assign int_uf_exp = dst_is_int_pre && (input_exp_pre < -1);
  assign int_uf     = int_uf_exp && !int_ovf;
  assign raw_inf   = ~dst_is_int_pre && ~src_is_int_pre && info_pre.is_inf;
  assign raw_ovf   = ~dst_is_int_pre && (destination_exp_q >= exp_max_s);
  assign raw_den   = ~dst_is_int_pre && (destination_exp_q < 1)
                     && (destination_exp_q >= -signed'(man_dst));
  assign raw_stk   = ~dst_is_int_pre && (destination_exp_q < -signed'(man_dst));
  assign oh_inf    = raw_inf;
  assign oh_ovf    = raw_ovf & ~raw_inf;
  assign oh_den    = raw_den & ~raw_inf & ~raw_ovf;
  assign oh_stk    = raw_stk & ~raw_inf & ~raw_ovf & ~raw_den;

  assign shamt_base = SUPER_MAN_BITS - man_dst;
  assign shamt_int  = unsigned'(MAX_INT_WIDTH - 1 - input_exp_pre);
  assign shamt_den  = unsigned'(shamt_base + 1 - destination_exp_q);
  assign shamt_stk  = unsigned'(shamt_base + 2 + man_dst);
  assign denorm_shamt = dst_is_int_pre
      ? (int_ovf ? '0 : int_uf_exp ? unsigned'(MAX_INT_WIDTH + 1) : shamt_int)
      : (oh_den ? shamt_den : oh_stk ? shamt_stk : shamt_base);
  // Saturation exponent is only a function of the destination format,
  // so it is not in series with the denorm compares.
  logic [INT_EXP_WIDTH-1:0] exp_sat_u;
  assign exp_sat_u = unsigned'(exp_max_s - INT_EXP_WIDTH'(1));
  assign final_exp = oh_inf ? unsigned'(exp_max_s)
                   : oh_ovf ? exp_sat_u
                   : (oh_den | oh_stk) ? '0
                   : unsigned'(destination_exp_q);
  assign of_before_round = int_ovf | oh_ovf;
  assign uf_before_round = int_uf | oh_den | oh_stk;
  assign preshift_zero   = oh_inf;
  assign preshift_ones   = oh_ovf;

  // Normal placement is a constant offset of the renormalized mantissa.
  assign preshift_mant = preshift_zero ? '0
                       : preshift_ones ? '1
                       : {input_mant_q, {(INT_MAN_WIDTH + 1){1'b0}}};

  localparam NUM_FP_STICKY  = 2 * INT_MAN_WIDTH - SUPER_MAN_BITS - 1; // removed mantissa, 1. and R
  localparam NUM_INT_STICKY = 2 * INT_MAN_WIDTH - MAX_INT_WIDTH; // removed int and R

  // One cycle between normalize / cast_value and the denorm barrel.
  // Ready/valid matches the fpnew pipes: a stall holds the shift
  // operands with the tag, and out_valid leaves with the result.
  // Callers: fpu_wrap presents fpu_valid_o from out_valid_o. The IQ
  // speculative wakeup for LAT_FP_FIXED is FP_LAT in g6lc_iq_bank,
  // bumped with this stage so a cast consumer is not armed earlier
  // than it was before the extra cycle.
  logic                            shift_ready, shift_valid_q, shift_ena;
  logic [2*INT_MAN_WIDTH:0]        preshift_q;
  logic [$clog2(INT_MAN_WIDTH+1)-1:0] denorm_shamt_q;
  logic [INT_EXP_WIDTH-1:0]        final_exp_q;
  logic                            of_before_round_q;
  TagType                          tag_s;
  logic                            mask_s;
  AuxType                          aux_s;

  assign shift_ready = post_ready | ~shift_valid_q;
  assign shift_ena   = shift_ready & mid_pipe_valid_q[NUM_MID_REGS];

  // Three captures so a later field is not billed as depending on
  // an earlier field's cone. Same enable, so they stay one instruction.
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_cast_valid
    if (!rst_ni) begin
      shift_valid_q <= 1'b0;
      tag_s         <= TagType'('0);
      mask_s        <= 1'b0;
      aux_s         <= AuxType'('0);
    end else begin
      if (flush_i) shift_valid_q <= 1'b0;
      else if (shift_ready) shift_valid_q <= mid_pipe_valid_q[NUM_MID_REGS];
      if (shift_ena) begin
        tag_s  <= mid_pipe_tag_q[NUM_MID_REGS];
        mask_s <= mid_pipe_mask_q[NUM_MID_REGS];
        aux_s  <= mid_pipe_aux_q[NUM_MID_REGS];
      end
    end
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_cast_preshift
    if (!rst_ni) preshift_q <= '0;
    else if (shift_ena) preshift_q <= preshift_mant;
  end
  always_ff @(posedge clk_i or negedge rst_ni) begin : p_cast_shamt
    if (!rst_ni) begin
      denorm_shamt_q    <= '0;
      final_exp_q       <= '0;
      of_before_round_q <= 1'b0;
      input_sign_q      <= 1'b0;
      input_exp_q       <= '0;
      src_is_int_q      <= 1'b0;
      dst_is_int_q      <= 1'b0;
      info_q            <= '0;
      mant_is_zero_q    <= 1'b0;
      op_mod_q2         <= 1'b0;
      rnd_mode_q        <= fpnew_pkg::RNE;
      dst_fmt_q2        <= fpnew_pkg::fp_format_e'(0);
      int_fmt_q2        <= fpnew_pkg::int_format_e'(0);
    end else if (shift_ena) begin
      denorm_shamt_q    <= denorm_shamt;
      final_exp_q       <= final_exp;
      of_before_round_q <= of_before_round;
      input_sign_q      <= input_sign_pre;
      input_exp_q       <= input_exp_pre;
      src_is_int_q      <= src_is_int_pre;
      dst_is_int_q      <= dst_is_int_pre;
      info_q            <= info_pre;
      mant_is_zero_q    <= mant_is_zero_pre;
      op_mod_q2         <= op_mod_pre;
      rnd_mode_q        <= rnd_mode_pre;
      dst_fmt_q2        <= dst_fmt_pre;
      int_fmt_q2        <= int_fmt_pre;
    end
  end

  // Mantissa adjustment shift, from the registered operands.
  assign destination_mant = preshift_q >> denorm_shamt_q;
  // Extract final mantissa and round bit, discard the normal bit (for FP)
  assign {final_mant, fp_round_sticky_bits[1]} =
      destination_mant[2*INT_MAN_WIDTH-1-:SUPER_MAN_BITS+1];
  assign {final_int, int_round_sticky_bits[1]} = destination_mant[2*INT_MAN_WIDTH-:MAX_INT_WIDTH+1];
  // Collapse sticky bits
  assign fp_round_sticky_bits[0]  = (| {destination_mant[NUM_FP_STICKY-1:0]});
  assign int_round_sticky_bits[0] = (| {destination_mant[NUM_INT_STICKY-1:0]});

  // select RS bits for destination operation
  assign round_sticky_bits = dst_is_int_q ? int_round_sticky_bits : fp_round_sticky_bits;

  // ----------------------------
  // Rounding and classification
  // ----------------------------
  logic [WIDTH-1:0] pre_round_abs;  // absolute value of result before rnd
  logic             of_after_round; // overflow
  logic             uf_after_round; // underflow

  logic [NUM_FORMATS-1:0][WIDTH-1:0] fmt_pre_round_abs; // per format
  logic [NUM_FORMATS-1:0]            fmt_of_after_round;
  logic [NUM_FORMATS-1:0]            fmt_uf_after_round;

  logic [NUM_INT_FORMATS-1:0][WIDTH-1:0] ifmt_pre_round_abs;      // per format
  logic [NUM_INT_FORMATS-1:0][WIDTH-1:0] ifmt_rounded_signed_res; // per format
  logic [NUM_INT_FORMATS-1:0]            ifmt_of_after_round;

  logic             rounded_sign;
  logic [WIDTH-1:0] rounded_abs; // absolute value of result after rounding
  logic             result_true_zero;

  logic [WIDTH-1:0] rounded_uint_res;     // after possible inversion
  logic [WIDTH-1:0] rounded_int_res;      // sign-extended, after possible inversion
  logic             rounded_int_res_zero; // after rounding


  // Pack exponent and mantissa into proper rounding form
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_res_assemble
    // Set up some constants
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (FpFmtConfig[fmt]) begin : active_format
      always_comb begin : assemble_result
        fmt_pre_round_abs[fmt] = {final_exp_q[EXP_BITS-1:0], final_mant[MAN_BITS-1:0]}; // 0-extend
      end
    end else begin : inactive_format
      assign fmt_pre_round_abs[fmt] = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // Zero-extend integer result
  for (genvar ifmt = 0; ifmt < int'(NUM_INT_FORMATS); ifmt++) begin : gen_int_res_zero_ext
    // Set up some constants
    localparam int unsigned INT_WIDTH = fpnew_pkg::int_width(fpnew_pkg::int_format_e'(ifmt));

    if (IntFmtConfig[ifmt]) begin : active_format
      always_comb begin : assemble_result
        // zero-extend absolute value result
        ifmt_pre_round_abs[ifmt]                = '0;
        ifmt_pre_round_abs[ifmt][INT_WIDTH-1:0] = final_int[INT_WIDTH-1:0];
      end
    end else begin : inactive_format
      assign ifmt_pre_round_abs[ifmt] = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // Select output with destination format and operation
  assign pre_round_abs = dst_is_int_q ? ifmt_pre_round_abs[int_fmt_q2] : fmt_pre_round_abs[dst_fmt_q2];

  fpnew_rounding #(
    .AbsWidth ( WIDTH )
  ) i_fpnew_rounding (
    .abs_value_i             ( pre_round_abs     ),
    .sign_i                  ( input_sign_q      ), // source format
    .round_sticky_bits_i     ( round_sticky_bits ),
    .rnd_mode_i              ( rnd_mode_q        ),
    .effective_subtraction_i ( 1'b0              ), // no operation happened
    .abs_rounded_o           ( rounded_abs_d     ),
    .sign_o                  ( rounded_sign_d    ),
    .exact_zero_o            ( result_true_zero_d)
  );

  // Integer two's-complement and the result mux sit past this edge.
  // fpu_wrap's out_valid follows it; FP_LAT in g6lc_iq_bank counts it.
  logic                            post_ready, post_valid_q, post_ena;
  logic [WIDTH-1:0]                rounded_abs_d, pre_round_q;
  logic                            rounded_sign_d, result_true_zero_d;
  logic                            sticky_hi_q;
  logic [1:0]                      fp_sticky_q, int_sticky_q;
  logic                            dst_is_int_r, src_is_int_r, mant_zero_r, op_mod_r;
  logic                            input_sign_r;
  logic signed [INT_EXP_WIDTH-1:0] input_exp_r;
  fpnew_pkg::fp_info_t             info_r;
  fpnew_pkg::roundmode_e           rnd_mode_r;
  fpnew_pkg::fp_format_e           dst_fmt_r;
  fpnew_pkg::int_format_e          int_fmt_r;
  logic                            of_before_r;
  TagType                          tag_r;
  logic                            mask_r;
  AuxType                          aux_r;

  assign post_ready = uint_ready | ~post_valid_q;
  assign post_ena   = post_ready & shift_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_cast_post
    if (!rst_ni) begin
      post_valid_q     <= 1'b0;
      rounded_abs      <= '0;
      rounded_sign     <= 1'b0;
      result_true_zero <= 1'b0;
      pre_round_q      <= '0;
      sticky_hi_q      <= 1'b0;
      fp_sticky_q      <= '0;
      int_sticky_q     <= '0;
      dst_is_int_r     <= 1'b0;
      src_is_int_r     <= 1'b0;
      mant_zero_r      <= 1'b0;
      op_mod_r         <= 1'b0;
      input_sign_r     <= 1'b0;
      input_exp_r      <= '0;
      info_r           <= '0;
      rnd_mode_r       <= fpnew_pkg::RNE;
      dst_fmt_r        <= fpnew_pkg::fp_format_e'(0);
      int_fmt_r        <= fpnew_pkg::int_format_e'(0);
      of_before_r      <= 1'b0;
      tag_r            <= TagType'('0);
      mask_r           <= 1'b0;
      aux_r            <= AuxType'('0);
    end else begin
      if (flush_i) post_valid_q <= 1'b0;
      else if (post_ready) post_valid_q <= shift_valid_q;
      if (post_ena) begin
        rounded_abs      <= rounded_abs_d;
        rounded_sign     <= rounded_sign_d;
        result_true_zero <= result_true_zero_d;
        pre_round_q      <= pre_round_abs;
        sticky_hi_q      <= destination_mant[NUM_FP_STICKY-1];
        fp_sticky_q      <= fp_round_sticky_bits;
        int_sticky_q     <= int_round_sticky_bits;
        dst_is_int_r     <= dst_is_int_q;
        src_is_int_r     <= src_is_int_q;
        mant_zero_r      <= mant_is_zero_q;
        op_mod_r         <= op_mod_q2;
        input_sign_r     <= input_sign_q;
        input_exp_r      <= input_exp_q;
        info_r           <= info_q;
        rnd_mode_r       <= rnd_mode_q;
        dst_fmt_r        <= dst_fmt_q2;
        int_fmt_r        <= int_fmt_q2;
        of_before_r      <= of_before_round_q;
        tag_r            <= tag_s;
        mask_r           <= mask_s;
        aux_r            <= aux_s;
      end
    end
  end

  logic [NUM_FORMATS-1:0][WIDTH-1:0] fmt_result;

  // Detect overflows and inject sign
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_sign_inject
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    if (FpFmtConfig[fmt]) begin : active_format
      always_comb begin : post_process
        // detect of / uf
        fmt_uf_after_round[fmt] = (abs_u[EXP_BITS+MAN_BITS-1:MAN_BITS] == '0) // denormal
            || ((pre_round_u[EXP_BITS+MAN_BITS-1:MAN_BITS] == '0) && (abs_u[EXP_BITS+MAN_BITS-1:MAN_BITS] == 1) &&
               ((fp_sticky_u != 2'b11) || (!sticky_hi_u && ((rnd_mode_u == fpnew_pkg::RNE) || (rnd_mode_u == fpnew_pkg::RMM)))));
        fmt_of_after_round[fmt] = abs_u[EXP_BITS+MAN_BITS-1:MAN_BITS] == '1; // inf exp.

        // Assemble regular result, nan box short ones. Int zeroes need to be detected`
        fmt_result[fmt]               = '1;
        fmt_result[fmt][FP_WIDTH-1:0] = src_is_int_u & mant_zero_u
                                        ? '0
                                        : {sign_u, abs_u[EXP_BITS+MAN_BITS-1:0]};
      end
    end else begin : inactive_format
      assign fmt_uf_after_round[fmt] = fpnew_pkg::DONT_CARE;
      assign fmt_of_after_round[fmt] = fpnew_pkg::DONT_CARE;
      assign fmt_result[fmt]         = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // Negative integer result needs to be brought into two's complement
  assign rounded_uint_res      = rounded_sign ? unsigned'(-rounded_abs) : rounded_abs;

  // Negate lands here. Sign-extend and the result mux read uint_q,
  // so they are not in the adder's cone. out_valid moves with them.
  logic                            uint_ready, uint_valid_q, uint_ena;
  logic [WIDTH-1:0]                uint_q, abs_u, pre_round_u;
  logic                            sign_u, sticky_hi_u, dst_is_int_u, src_is_int_u;
  logic                            mant_zero_u, op_mod_u, input_sign_u, of_before_u;
  logic [1:0]                      fp_sticky_u, int_sticky_u;
  logic signed [INT_EXP_WIDTH-1:0] input_exp_u;
  fpnew_pkg::fp_info_t             info_u;
  fpnew_pkg::roundmode_e           rnd_mode_u;
  fpnew_pkg::fp_format_e           dst_fmt_u;
  fpnew_pkg::int_format_e          int_fmt_u;
  TagType                          tag_u;
  logic                            mask_u;
  AuxType                          aux_u;

  assign uint_ready = out_pipe_ready[0] | ~uint_valid_q;
  assign uint_ena   = uint_ready & post_valid_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_cast_uint
    if (!rst_ni) begin
      uint_valid_q <= 1'b0;
      uint_q       <= '0;
      abs_u        <= '0;
      pre_round_u  <= '0;
      sign_u       <= 1'b0;
      sticky_hi_u  <= 1'b0;
      fp_sticky_u  <= '0;
      int_sticky_u <= '0;
      dst_is_int_u <= 1'b0;
      src_is_int_u <= 1'b0;
      mant_zero_u  <= 1'b0;
      op_mod_u     <= 1'b0;
      input_sign_u <= 1'b0;
      input_exp_u  <= '0;
      info_u       <= '0;
      rnd_mode_u   <= fpnew_pkg::RNE;
      dst_fmt_u    <= fpnew_pkg::fp_format_e'(0);
      int_fmt_u    <= fpnew_pkg::int_format_e'(0);
      of_before_u  <= 1'b0;
      tag_u        <= TagType'('0);
      mask_u       <= 1'b0;
      aux_u        <= AuxType'('0);
    end else begin
      if (flush_i) uint_valid_q <= 1'b0;
      else if (uint_ready) uint_valid_q <= post_valid_q;
      if (uint_ena) begin
        uint_q       <= rounded_uint_res;
        abs_u        <= rounded_abs;
        pre_round_u  <= pre_round_q;
        sign_u       <= rounded_sign;
        sticky_hi_u  <= sticky_hi_q;
        fp_sticky_u  <= fp_sticky_q;
        int_sticky_u <= int_sticky_q;
        dst_is_int_u <= dst_is_int_r;
        src_is_int_u <= src_is_int_r;
        mant_zero_u  <= mant_zero_r;
        op_mod_u     <= op_mod_r;
        input_sign_u <= input_sign_r;
        input_exp_u  <= input_exp_r;
        info_u       <= info_r;
        rnd_mode_u   <= rnd_mode_r;
        dst_fmt_u    <= dst_fmt_r;
        int_fmt_u    <= int_fmt_r;
        of_before_u  <= of_before_r;
        tag_u        <= tag_r;
        mask_u       <= mask_r;
        aux_u        <= aux_r;
      end
    end
  end

    // Sign-extend integer result
  for (genvar ifmt = 0; ifmt < int'(NUM_INT_FORMATS); ifmt++) begin : gen_int_res_sign_ext
    // Set up some constants
    localparam int unsigned INT_WIDTH = fpnew_pkg::int_width(fpnew_pkg::int_format_e'(ifmt));

    if (IntFmtConfig[ifmt]) begin : active_format
      // Sign-extend. INT_WIDTH is a constant per format, so the
      // replicated bit is a fixed index, not a barrel.
      assign ifmt_rounded_signed_res[ifmt] = {
        {(WIDTH - INT_WIDTH){uint_q[INT_WIDTH-1]}},
        uint_q[INT_WIDTH-1:0]
      };
    end else begin : inactive_format
      assign ifmt_rounded_signed_res[ifmt] = '{default: fpnew_pkg::DONT_CARE};
    end
  end
  
  assign rounded_int_res = ifmt_rounded_signed_res[int_fmt_u];
  assign rounded_int_res_zero = (rounded_int_res == '0) && (pre_round_u == '0);

  // Detect integer overflows after rounding (only positives)
  for (genvar ifmt = 0; ifmt < int'(NUM_INT_FORMATS); ifmt++) begin : gen_int_overflow
    // Set up some constants
    localparam int unsigned INT_WIDTH = fpnew_pkg::int_width(fpnew_pkg::int_format_e'(ifmt));

    if (IntFmtConfig[ifmt]) begin : active_format
      // op_mod selects bit INT_WIDTH-1 (unsigned) or INT_WIDTH-2
      // (signed). Both indexes are constant; a variable part-select
      // of the whole word is a barrel.
      logic pos_bit, neg_bit;
      always_comb begin
        unique case (op_mod_u)
          1'b1:    pos_bit = ifmt_rounded_signed_res[ifmt][INT_WIDTH-1];
          default: pos_bit = ifmt_rounded_signed_res[ifmt][INT_WIDTH-2];
        endcase
      end
      assign neg_bit = uint_q[INT_WIDTH-1];
      assign ifmt_of_after_round[ifmt] =
          (!sign_u && (input_exp_u == signed'(INT_WIDTH - 2 + op_mod_u)) && ~pos_bit)
          || (!op_mod_u && sign_u && (input_exp_u == signed'(INT_WIDTH - 1)) && ~neg_bit);
    end else begin : inactive_format
      assign ifmt_of_after_round[ifmt] = fpnew_pkg::DONT_CARE;
    end
  end

  // Classification after rounding select by destination format
  assign uf_after_round = fmt_uf_after_round[dst_fmt_u];
  assign of_after_round = dst_is_int_u ? ifmt_of_after_round[int_fmt_u] : fmt_of_after_round[dst_fmt_u];

  // -------------------------
  // FP Special case handling
  // -------------------------
  logic [WIDTH-1:0]   fp_special_result;
  fpnew_pkg::status_t fp_special_status;
  logic               fp_result_is_special;

  logic [NUM_FORMATS-1:0][WIDTH-1:0] fmt_special_result;

  // Special result construction
  for (genvar fmt = 0; fmt < int'(NUM_FORMATS); fmt++) begin : gen_special_results
    // Set up some constants
    localparam int unsigned FP_WIDTH = fpnew_pkg::fp_width(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned EXP_BITS = fpnew_pkg::exp_bits(fpnew_pkg::fp_format_e'(fmt));
    localparam int unsigned MAN_BITS = fpnew_pkg::man_bits(fpnew_pkg::fp_format_e'(fmt));

    localparam logic [EXP_BITS-1:0] QNAN_EXPONENT = '1;
    localparam logic [MAN_BITS-1:0] QNAN_MANTISSA = 2**(MAN_BITS-1);

    if (FpFmtConfig[fmt]) begin : active_format
      always_comb begin : special_results
        logic [FP_WIDTH-1:0] special_res;
        special_res = info_u.is_zero
                      ? input_sign_u << FP_WIDTH-1 // signed zero
                      : {1'b0, QNAN_EXPONENT, QNAN_MANTISSA}; // qNaN

        // Initialize special result with ones (NaN-box)
        fmt_special_result[fmt]               = '1;
        fmt_special_result[fmt][FP_WIDTH-1:0] = special_res;
      end
    end else begin : inactive_format
      assign fmt_special_result[fmt] = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // Detect special case from source format, I2F casts don't produce a special result
  assign fp_result_is_special = ~src_is_int_u & (info_u.is_zero |
                                                 info_u.is_nan |
                                                 ~info_u.is_boxed);

  // Signalling input NaNs raise invalid flag, otherwise no flags set
  assign fp_special_status = '{NV: info_u.is_signalling, default: 1'b0};

  // Assemble result according to destination format
  assign fp_special_result = fmt_special_result[dst_fmt_u]; // destination format

  // --------------------------
  // INT Special case handling
  // --------------------------
  logic [WIDTH-1:0]   int_special_result;
  fpnew_pkg::status_t int_special_status;
  logic               int_result_is_special;

  logic [NUM_INT_FORMATS-1:0][WIDTH-1:0] ifmt_special_result;

  // Special result construction
  for (genvar ifmt = 0; ifmt < int'(NUM_INT_FORMATS); ifmt++) begin : gen_special_results_int
    // Set up some constants
    localparam int unsigned INT_WIDTH = fpnew_pkg::int_width(fpnew_pkg::int_format_e'(ifmt));

    if (IntFmtConfig[ifmt]) begin : active_format
      always_comb begin : special_results
        automatic logic [INT_WIDTH-1:0] special_res;

        // Default is overflow to positive max, which is 2**INT_WIDTH-1 or 2**(INT_WIDTH-1)-1
        special_res[INT_WIDTH-2:0] = '1;       // alone yields 2**(INT_WIDTH-1)-1
        special_res[INT_WIDTH-1]   = op_mod_u; // for unsigned casts yields 2**INT_WIDTH-1

        // Negative special case (except for nans) tie to -max or 0
        if (input_sign_u && !info_u.is_nan)
          special_res = ~special_res;

        // Initialize special result with sign-extension
        ifmt_special_result[ifmt]                = '{default: special_res[INT_WIDTH-1]};
        ifmt_special_result[ifmt][INT_WIDTH-1:0] = special_res;
      end
    end else begin : inactive_format
      assign ifmt_special_result[ifmt] = '{default: fpnew_pkg::DONT_CARE};
    end
  end

  // Overflow-after-round is the long cone. The other special causes do
  // not read it, so they are one OR beside that cone instead of inside it.
  logic int_special_base;
  assign int_special_base = info_u.is_nan | info_u.is_inf | of_before_u
                          | ~info_u.is_boxed
                          | (input_sign_u & op_mod_u & ~rounded_int_res_zero);
  assign int_result_is_special = int_special_base | of_after_round;

  // All integer special cases are invalid
  assign int_special_status = '{NV: 1'b1, default: 1'b0};

  // Assemble result according to destination format
  assign int_special_result = ifmt_special_result[int_fmt_u]; // destination format

  // -----------------
  // Result selection
  // -----------------
  fpnew_pkg::status_t int_regular_status, fp_regular_status;

  logic [WIDTH-1:0]   fp_result, int_result;
  fpnew_pkg::status_t fp_status, int_status;

  // Inexact is status-only. Overflow-after-round stays one select
  // because the integer result reads that same bit.
  logic nx_sticky, nx_src, nx_of, nx_ovf;
  assign nx_sticky = |fp_sticky_u;
  assign nx_src = src_is_int_u | ~info_u.is_inf;
  assign nx_of  = of_before_u | of_after_round;
  assign nx_ovf = nx_src & nx_of;
  assign fp_regular_status.NV = 1'b0; // floating-point results are always valid
  assign fp_regular_status.DZ = 1'b0; // no divisions
  assign fp_regular_status.OF = nx_ovf; // inf casts no OF
  assign fp_regular_status.NX = nx_sticky | nx_ovf;
  assign fp_regular_status.UF = uf_after_round & fp_regular_status.NX;
  assign int_regular_status = '{NV: of_before_u | of_after_round, // overflow is invalid for F2I casts
                                NX: (| int_sticky_u), default: 1'b0};

  assign fp_result  = fp_result_is_special  ? fp_special_result  : fmt_result[dst_fmt_u];
  assign fp_status  = fp_result_is_special  ? fp_special_status  : fp_regular_status;
  assign int_result = int_result_is_special ? int_special_result : rounded_int_res;
  assign int_status = int_result_is_special ? int_special_status : int_regular_status;

  // Final results for output pipeline
  logic [WIDTH-1:0]   result_d;
  fpnew_pkg::status_t status_d;
  logic               extension_bit;

  // Select output depending on special case detection
  assign result_d = dst_is_int_u ? int_result : fp_result;
  assign status_d = dst_is_int_u ? int_status : fp_status;

  // MSB of int result decides extension, otherwise NaN box
  assign extension_bit = dst_is_int_u ? int_result[WIDTH-1] : 1'b1;

  // ----------------
  // Output Pipeline
  // ----------------
  // Output pipeline signals, index i holds signal after i register stages
  logic               [0:NUM_OUT_REGS][WIDTH-1:0] out_pipe_result_q;
  fpnew_pkg::status_t [0:NUM_OUT_REGS]            out_pipe_status_q;
  logic               [0:NUM_OUT_REGS]            out_pipe_ext_bit_q;
  TagType             [0:NUM_OUT_REGS]            out_pipe_tag_q;
  logic               [0:NUM_OUT_REGS]            out_pipe_mask_q;
  AuxType             [0:NUM_OUT_REGS]            out_pipe_aux_q;
  logic               [0:NUM_OUT_REGS]            out_pipe_valid_q;
  // Ready signal is combinatorial for all stages
  logic [0:NUM_OUT_REGS] out_pipe_ready;

  // Input stage: First element of pipeline is taken from inputs
  assign out_pipe_result_q[0]  = result_d;
  assign out_pipe_status_q[0]  = status_d;
  assign out_pipe_ext_bit_q[0] = extension_bit;
  assign out_pipe_tag_q[0]     = tag_u;
  assign out_pipe_mask_q[0]    = mask_u;
  assign out_pipe_aux_q[0]     = aux_u;
  assign out_pipe_valid_q[0]   = uint_valid_q;
  // Backpressure reaches the mid pipe through the shift stage.
  assign mid_pipe_ready[NUM_MID_REGS] = shift_ready;
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
    `FFL(out_pipe_result_q[i+1],  out_pipe_result_q[i],  reg_ena, '0)
    `FFL(out_pipe_status_q[i+1],  out_pipe_status_q[i],  reg_ena, '0)
    `FFL(out_pipe_ext_bit_q[i+1], out_pipe_ext_bit_q[i], reg_ena, '0)
    `FFL(out_pipe_tag_q[i+1],     out_pipe_tag_q[i],     reg_ena, TagType'('0))
    `FFL(out_pipe_mask_q[i+1],    out_pipe_mask_q[i],    reg_ena, '0)
    `FFL(out_pipe_aux_q[i+1],     out_pipe_aux_q[i],     reg_ena, AuxType'('0))
  end
  // Output stage: Ready travels backwards from output side, driven by downstream circuitry
  assign out_pipe_ready[NUM_OUT_REGS] = out_ready_i;
  // Output stage: assign module outputs
  assign result_o        = out_pipe_result_q[NUM_OUT_REGS];
  assign status_o        = out_pipe_status_q[NUM_OUT_REGS];
  assign extension_bit_o = out_pipe_ext_bit_q[NUM_OUT_REGS];
  assign tag_o           = out_pipe_tag_q[NUM_OUT_REGS];
  assign mask_o          = out_pipe_mask_q[NUM_OUT_REGS];
  assign aux_o           = out_pipe_aux_q[NUM_OUT_REGS];
  assign out_valid_o     = out_pipe_valid_q[NUM_OUT_REGS];
  assign busy_o          = (| {inp_pipe_valid_q, int_valid_q, renorm_valid_q, align_valid_q, mid_pipe_valid_q, shift_valid_q, post_valid_q, uint_valid_q, out_pipe_valid_q});

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
