// hyp8 provenance: REWRITTEN (split of <src>/core/decoder.sv at the 8-FO4
// budget; all decode arms carried over verbatim)
// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Modifications (c) 2026 Etienne Cimon: split into three combinational decode
// stages for the hyp8 8-FO4 pipeline (decoder T1 D=63.2, rank 4 front-end
// depth). Behaviour is identical to the original single-comb decoder.
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial

// g6lc_decode_s2 (D2): instruction-bit-only decode -- the original decoder's
// opcode/funct case, register and immediate selection, verbatim minus the
// privilege/CSR-state checks, which moved to g6lc_decode_s3 (they read live
// architectural state, not instruction bits). fp_hit/frm_req/check_fprm are
// arm-hit evidence consumed by s3.

module g6lc_decode_s2
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type branchpredict_sbe_t = logic,
    parameter type exception_t = logic,
    parameter type scoreboard_entry_t = logic
) (
    input  logic [31:0]                     instruction_i,
    input  logic [15:0]                     compressed_instr_i,
    input  logic                            is_compressed_i,
    input  logic                            is_illegal_i,
    input  logic                            is_macro_instr_i,
    input  logic                            is_last_macro_instr_i,
    input  logic                            is_double_rd_macro_instr_i,
    input  logic                            is_zcmt_i,
    input  logic [G6LCCfg.XLEN-1:0]         jump_address_i,
    input  branchpredict_sbe_t              branch_predict_i,
    input  exception_t                      ex_i,
    input  logic [G6LCCfg.VLEN-1:0]         pc_i,
    input  logic [((G6LCCfg.NrHarts <= 1) ? 1 : $clog2(G6LCCfg.NrHarts))-1:0]                smt_hart_id_i,
    // partially-assembled scoreboard entry (valid/ex filled by s3)
    output scoreboard_entry_t               sbe_o,
    output logic [31:0]                     instr_o,
    output logic [31:0]                     tinst_o,
    output logic [15:0]                     compressed_instr_o,
    output logic                            is_compressed_o,
    output logic                            is_illegal_o,
    output exception_t                      ex_o,
    output logic                            ecall_o,
    output logic                            ebreak_o,
    output logic                            frm_req_o,
    output logic                            check_fprm_o,
    output logic                            fp_hit_o,
    output logic                            illegal_o,
    output logic                            cf_o
);
  logic illegal_bit;
  logic illegal_instr_bm;
  logic illegal_instr_zic;
  logic illegal_instr_non_bm;
  // this instruction is an environment call (ecall), it is handled like an exception
  logic ecall;
  // this instruction is a software break-point
  logic ebreak;
  // this instruction needs floating-point rounding-mode verification
  logic check_fprm;
  // an fs/vfs-gated FP/vector arm decoded this instruction (s3 applies the gate)
  logic fp_hit;
  // a D2 arm requests dynamic-rounding-mode legality at s3
  logic frm_req;
  scoreboard_entry_t cand;
  riscv::instruction_t instr;
  assign instr = riscv::instruction_t'(instruction_i);
  // transformed instruction
  logic [31:0] tinst;
  // --------------------
  // Immediate select
  // --------------------
  enum logic [3:0] {
    NOIMM,
    IIMM,
    SIMM,
    SBIMM,
    UIMM,
    JIMM,
    RS3,
    MUX_RD_RS3
  } imm_select;

  logic [G6LCCfg.XLEN-1:0] imm_i_type;
  logic [G6LCCfg.XLEN-1:0] imm_s_type;
  logic [G6LCCfg.XLEN-1:0] imm_sb_type;
  logic [G6LCCfg.XLEN-1:0] imm_u_type;
  logic [G6LCCfg.XLEN-1:0] imm_uj_type;

  assign sbe_o              = cand;
  assign instr_o            = instruction_i;
  assign tinst_o            = tinst;
  assign compressed_instr_o = compressed_instr_i;
  assign is_compressed_o    = is_compressed_i;
  assign is_illegal_o       = is_illegal_i;
  assign ex_o               = ex_i;
  assign ecall_o            = ecall;
  assign ebreak_o           = ebreak;
  assign check_fprm_o       = check_fprm;
  assign fp_hit_o           = fp_hit;
  assign frm_req_o          = frm_req;
  assign illegal_o          = illegal_bit;

  always_comb begin : decoder

    fp_hit                                 = 1'b0;
    frm_req                                = 1'b0;

    cand.valid                             = 1'b0;  // hyp8: valid/ex are s3 fields
    cand.ex                                = '0;
    imm_select                             = NOIMM;
    cf_o                = 1'b0;
    illegal_bit                          = 1'b0;
    illegal_instr_non_bm                   = 1'b0;
    illegal_instr_bm                       = 1'b0;
    illegal_instr_zic                      = 1'b0;
    cand.pc                       = pc_i;
    cand.trans_id                 = '0;
    cand.fu                       = NONE;
    cand.op                       = g6lc_core_pkg::ADD;
    cand.rs1                      = '0;
    cand.rs2                      = '0;
    cand.rd                       = '0;
    cand.use_pc                   = 1'b0;
    cand.is_compressed            = is_compressed_i;
    cand.is_macro_instr           = is_macro_instr_i;
    cand.is_last_macro_instr      = is_last_macro_instr_i;
    cand.is_double_rd_macro_instr = is_double_rd_macro_instr_i;
    cand.use_zimm                 = 1'b0;
    cand.bp                       = branch_predict_i;
    cand.vfp                      = 1'b0;
    cand.is_zcmt                  = is_zcmt_i;
    cand.hart_id                  = smt_hart_id_i;
    ecall                                  = 1'b0;
    ebreak                                 = 1'b0;
    check_fprm                             = 1'b0;
    tinst                                  = 32'h0;

    if (~ex_i.valid) begin
      case (instr.rtype.opcode)
        riscv::OpcodeSystem: begin
          cand.fu = CSR;
          cand.rs1 = instr.itype.rs1;
          cand.rs2 = instr.rtype.rs2;   //TODO: needs to be checked if better way is available
          cand.rd = instr.itype.rd;

          unique case (instr.itype.funct3)
            3'b000: begin
              // hyp8: rs1/rd-nonzero legality (v_i) deferred to g6lc_decode_s3
              // decode the immediate field
              case (instr.itype.imm)
                // ECALL -> inject exception
                12'b0: ecall = 1'b1;
                // EBREAK -> inject exception
                12'b1: ebreak = 1'b1;
                // SRET
                12'b1_0000_0010: begin
                  if (G6LCCfg.RVS) begin
                    cand.op = g6lc_core_pkg::SRET;
                    // hyp8: SRET priv/tsr legality deferred to g6lc_decode_s3
                  end else begin
                    illegal_bit = 1'b1;
                    cand.op = g6lc_core_pkg::ADD;
                  end
                end
                // MRET
                12'b11_0000_0010: begin
                  cand.op = g6lc_core_pkg::MRET;
                  // hyp8: MRET privilege check deferred to g6lc_decode_s3
                end
                // DRET
                12'b111_1011_0010: begin
                  cand.op = g6lc_core_pkg::DRET;
                  if (!G6LCCfg.DebugEn) begin
                    illegal_bit = 1'b1;
                  end
                  // hyp8: debug_mode_i check deferred to g6lc_decode_s3
                end
                // WFI
                12'b1_0000_0101: begin
                  cand.op = g6lc_core_pkg::WFI;
                  // hyp8: WFI tw/vtw/U legality deferred to g6lc_decode_s3
                end
                // Zawrs: WRS.NTO (imm=0x00d) / WRS.STO (imm=0x01d) — wait like WFI
                12'b0_0000_1101,  // WRS.NTO
                12'b0_0001_1101: begin  // WRS.STO
                  if (G6LCCfg.ZawrsEn) begin
                    // Same privilege/TW rules as WFI; STO timeout is microarch (treat as WFI)
                    cand.op = g6lc_core_pkg::WFI;
                    // hyp8: WRS tw/vtw/U legality deferred to g6lc_decode_s3
                  end else begin
                    illegal_bit = 1'b1;
                    cand.op = g6lc_core_pkg::ADD;
                  end
                end
                // SFENCE.VMA
                default: begin
                  // hyp8: sfence.vma / hfence.* priv+tvm legality deferred to
                  // g6lc_decode_s3 (keyed on the op decoded here).
                  if (instr.instr[31:25] == 7'b1001) begin
                    cand.op = g6lc_core_pkg::SFENCE_VMA;
                  end else if (G6LCCfg.RVH) begin
                    if (instr.instr[31:25] == 7'b10001) begin
                      cand.op = g6lc_core_pkg::HFENCE_VVMA;
                    end else if (instr.instr[31:25] == 7'b110001) begin
                      cand.op = g6lc_core_pkg::HFENCE_GVMA;
                    end else begin
                      illegal_bit = 1'b1;
                    end
                  end else begin
                    illegal_bit = 1'b1;
                  end
                end
              endcase
            end
            3'b100: begin
              // Hypervisor load/store instructions
              if (G6LCCfg.RVH) begin
                if (instr.instr[25] != 1'b0) begin
                  cand.fu = STORE;
                  imm_select = NOIMM;
                  cand.rs1 = instr.stype.rs1;
                  cand.rs2 = instr.stype.rs2;
                end else begin
                  cand.fu = LOAD;
                  imm_select = NOIMM;
                  cand.rs1 = instr.itype.rs1;
                  cand.rd = instr.itype.rd;
                end

                // hyp8: v_i/hu_i/priv legality for HLV/HSV deferred to g6lc_decode_s3
                unique case (instr.rtype.funct7)
                  7'b011_0000: begin
                    if (instr.rtype.rs2 == 5'b0) begin
                      cand.op = g6lc_core_pkg::HLV_B;
                    end
                    if (instr.rtype.rs2 == 5'b1) begin
                      cand.op = g6lc_core_pkg::HLV_BU;
                    end
                  end
                  7'b011_0010: begin
                    if (instr.rtype.rs2 == 5'b0) begin
                      cand.op = g6lc_core_pkg::HLV_H;
                    end
                    if (instr.rtype.rs2 == 5'b1) begin
                      cand.op = g6lc_core_pkg::HLV_HU;
                    end
                    if (instr.rtype.rs2 == 5'b11) begin
                      cand.op = g6lc_core_pkg::HLVX_HU;
                    end
                  end
                  7'b011_0100: begin
                    if (instr.rtype.rs2 == 5'b0) begin
                      cand.op = g6lc_core_pkg::HLV_W;
                    end
                    if (instr.rtype.rs2 == 5'b1) begin
                      cand.op = g6lc_core_pkg::HLV_WU;
                    end
                    if (instr.rtype.rs2 == 5'b11) begin
                      cand.op = g6lc_core_pkg::HLVX_WU;
                    end
                  end
                  7'b011_0001: cand.op = g6lc_core_pkg::HSV_B;
                  7'b011_0011: cand.op = g6lc_core_pkg::HSV_H;
                  7'b011_0101: cand.op = g6lc_core_pkg::HSV_W;
                  7'b011_0110: cand.op = g6lc_core_pkg::HLV_D;
                  7'b011_0111: cand.op = g6lc_core_pkg::HSV_D;
                  default: illegal_bit = 1'b1;

                endcase
                tinst = {
                  instr.rtype.funct7,
                  instr.rtype.rs2,
                  5'b0,
                  instr.rtype.funct3,
                  instr.rtype.rd,
                  instr.rtype.opcode
                };
              end else begin
                illegal_bit = 1'b1;
              end
            end
            // atomically swaps values in the CSR and integer register
            3'b001: begin  // CSRRW
              imm_select = IIMM;
              cand.op = g6lc_core_pkg::CSR_WRITE;
            end
            // atomically set values in the CSR and write back to rd
            3'b010: begin  // CSRRS
              imm_select = IIMM;
              // this is just a read
              if (instr.itype.rs1 == '0) cand.op = g6lc_core_pkg::CSR_READ;
              else cand.op = g6lc_core_pkg::CSR_SET;
            end
            // atomically clear values in the CSR and write back to rd
            3'b011: begin  // CSRRC
              imm_select = IIMM;
              // this is just a read
              if (instr.itype.rs1 == '0) cand.op = g6lc_core_pkg::CSR_READ;
              else cand.op = g6lc_core_pkg::CSR_CLEAR;
            end
            // use zimm and iimm
            3'b101: begin  // CSRRWI
              cand.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              cand.use_zimm = 1'b1;
              cand.op = g6lc_core_pkg::CSR_WRITE;
            end
            3'b110: begin  // CSRRSI
              cand.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              cand.use_zimm = 1'b1;
              // this is just a read
              if (instr.itype.rs1 == 5'b0) cand.op = g6lc_core_pkg::CSR_READ;
              else cand.op = g6lc_core_pkg::CSR_SET;
            end
            3'b111: begin  // CSRRCI
              cand.rs1 = instr.itype.rs1;
              imm_select = IIMM;
              cand.use_zimm = 1'b1;
              // this is just a read
              if (instr.itype.rs1 == '0) cand.op = g6lc_core_pkg::CSR_READ;
              else cand.op = g6lc_core_pkg::CSR_CLEAR;
            end
            default: illegal_bit = 1'b1;
          endcase
        end
        // Memory ordering instructions
        riscv::OpcodeMiscMem: begin
          cand.fu  = CSR;
          cand.rs1 = '0;
          cand.rs2 = '0;
          cand.rd  = '0;

          case (instr.stype.funct3)
            // FENCE — or PAUSE when Zihintpause is enabled.
            // PAUSE is the HINT encoding fm=0, pred=W, succ=0, rd=x0, rs1=x0
            // (imm[11:0] = 12'h010). Architecturally legal as a zero-duration HINT;
            // with ZihintpauseEn we decode it as a pure NOP so it does not flush D$.
            3'b000: begin
              if (G6LCCfg.ZihintpauseEn &&
                  instr.itype.rs1 == '0 &&
                  instr.itype.rd == '0 &&
                  instr.itype.imm == 12'h010) begin
                cand.fu  = ALU;
                cand.op  = g6lc_core_pkg::ADD;
                cand.rs1 = '0;
                cand.rs2 = '0;
                cand.rd  = '0;
              end else begin
                // Currently implemented as a whole DCache flush boldly ignoring other things
                cand.op = g6lc_core_pkg::FENCE;
              end
            end
            // FENCE.I
            3'b001: cand.op = g6lc_core_pkg::FENCE_I;
            // CBO — Zicbom (inval/clean/flush) and Zicboz (zero)
            3'b010: begin
              if (G6LCCfg.RVZiCbom || G6LCCfg.RVZiCboz) begin
                cand.fu = STORE;
                cand.rs1[4:0] = instr.itype.rs1;
                cand.rs2[4:0] = '0;
                unique case (instr.itype.imm)
                  // CBO.INVAL (Zicbom)
                  12'b000000000000: begin
                    if (G6LCCfg.RVZiCbom) cand.op = g6lc_core_pkg::CBO_INVAL;
                    else illegal_bit = 1'b1;
                  end
                  // CBO.CLEAN (Zicbom)
                  12'b000000000001: begin
                    if (G6LCCfg.RVZiCbom) cand.op = g6lc_core_pkg::CBO_CLEAN;
                    else illegal_bit = 1'b1;
                  end
                  // CBO.FLUSH (Zicbom)
                  12'b000000000010: begin
                    if (G6LCCfg.RVZiCbom) cand.op = g6lc_core_pkg::CBO_FLUSH;
                    else illegal_bit = 1'b1;
                  end
                  // CBO.ZERO (Zicboz) — imm[11:0] = 4
                  12'b000000000100: begin
                    if (G6LCCfg.RVZiCboz) cand.op = g6lc_core_pkg::CBO_ZERO;
                    else illegal_bit = 1'b1;
                  end
                  default: illegal_bit = 1'b1;
                endcase

                // hyp8: CBO.INVAL xenvcfg/priv legality + CBO_FLUSH demote
                // deferred to g6lc_decode_s3 (keyed on cand op CBO_INVAL)

                // hyp8: CBO.CLEAN/FLUSH cbcfe/priv legality deferred to g6lc_decode_s3

                // hyp8: CBO.ZERO cbze/priv legality deferred to g6lc_decode_s3
              end else begin
                illegal_bit = 1'b1;
              end

              if (G6LCCfg.RVH) begin
                tinst = {
                  instr.itype.imm, 5'b00000, instr.stype.funct3, 5'b00000, instr.stype.opcode
                };
              end
            end


            default: illegal_bit = 1'b1;
          endcase
        end

        // --------------------------
        // Reg-Reg Operations
        // --------------------------
        riscv::OpcodeOp: begin
          // --------------------------------------------
          // Vectorial Floating-Point Reg-Reg Operations
          // --------------------------------------------
          if (!G6LCCfg.ZKN && instr.rvftype.funct2 == 2'b10) begin  // Prefix 10 for all Xfvec ops
            // only generate decoder if FP extensions are enabled (static)
            if (G6LCCfg.FpPresent && G6LCCfg.XFVec) begin
              // hyp8 bring-up: block-item declaration must precede
              // statements; the hyp8 fp_hit assignment moved above it.
              automatic logic allow_replication;  // control honoring of replication flag
              fp_hit = 1'b1;  // hyp8: fs_i/vfs_i/v_i legality deferred to g6lc_decode_s3

              cand.fu  = FPU_VEC;  // Same unit, but sets 'vectorial' signal
              cand.rs1 = instr.rvftype.rs1;
              cand.rs2 = instr.rvftype.rs2;
              cand.rd  = instr.rvftype.rd;
              check_fprm        = 1'b1;
              allow_replication = 1'b1;
              // decode vectorial FP instruction
              unique case (instr.rvftype.vecfltop)
                5'b00001: begin
                  cand.op  = g6lc_core_pkg::FADD;  // vfadd.vfmt - Vectorial FP Addition
                  cand.rs1 = '0;  // Operand A is set to 0
                  cand.rs2 = instr.rvftype.rs1;  // Operand B is set to rs1
                  imm_select        = IIMM;  // Operand C is set to rs2
                end
                5'b00010: begin
                  cand.op = g6lc_core_pkg::FSUB;  // vfsub.vfmt - Vectorial FP Subtraction
                  cand.rs1 = '0;  // Operand A is set to 0
                  cand.rs2 = instr.rvftype.rs1;  // Operand B is set to rs1
                  imm_select = IIMM;  // Operand C is set to rs2
                end
                5'b00011:
                cand.op = g6lc_core_pkg::FMUL;  // vfmul.vfmt - Vectorial FP Multiplication
                5'b00100:
                cand.op = g6lc_core_pkg::FDIV;  // vfdiv.vfmt - Vectorial FP Division
                5'b00101: begin
                  cand.op = g6lc_core_pkg::VFMIN;  // vfmin.vfmt - Vectorial FP Minimum
                  check_fprm       = 1'b0;  // rounding mode irrelevant
                end
                5'b00110: begin
                  cand.op = g6lc_core_pkg::VFMAX;  // vfmax.vfmt - Vectorial FP Maximum
                  check_fprm       = 1'b0;  // rounding mode irrelevant
                end
                5'b00111: begin
                  cand.op  = g6lc_core_pkg::FSQRT;  // vfsqrt.vfmt - Vectorial FP Square Root
                  allow_replication = 1'b0;  // only one operand
                  if (instr.rvftype.rs2 != 5'b00000) illegal_bit = 1'b1;  // rs2 must be 0
                end
                5'b01000: begin
                  cand.op = g6lc_core_pkg::FMADD; // vfmac.vfmt - Vectorial FP Multiply-Accumulate
                  imm_select = SIMM;  // rd into result field (upper bits don't matter)
                end
                5'b01001: begin
                  cand.op = g6lc_core_pkg::FMSUB; // vfmre.vfmt - Vectorial FP Multiply-Reduce
                  imm_select = SIMM;  // rd into result field (upper bits don't matter)
                end
                5'b01100: begin
                  unique case (instr.rvftype.rs2) inside // operation encoded in rs2, `inside` for matching ?
                    5'b00000: begin
                      cand.rs2 = instr.rvftype.rs1; // set rs2 = rs1 so we can map FMV to SGNJ in the unit
                      if (instr.rvftype.repl)
                        cand.op = g6lc_core_pkg::FMV_X2F;  // vfmv.vfmt.x - GPR to FPR Move
                      else cand.op = g6lc_core_pkg::FMV_F2X;  // vfmv.x.vfmt - FPR to GPR Move
                      check_fprm = 1'b0;  // no rounding for moves
                    end
                    5'b00001: begin
                      cand.op  = g6lc_core_pkg::FCLASS; // vfclass.vfmt - Vectorial FP Classify
                      check_fprm = 1'b0;  // no rounding for classification
                      allow_replication = 1'b0;  // R must not be set
                    end
                    5'b00010:
                    cand.op = g6lc_core_pkg::FCVT_F2I; // vfcvt.x.vfmt - Vectorial FP to Int Conversion
                    5'b00011:
                    cand.op = g6lc_core_pkg::FCVT_I2F; // vfcvt.vfmt.x - Vectorial Int to FP Conversion
                    5'b001??: begin
                      cand.op       = g6lc_core_pkg::FCVT_F2F; // vfcvt.vfmt.vfmt - Vectorial FP to FP Conversion
                      cand.rs2 = instr.rvftype.rd; // set rs2 = rd as target vector for conversion
                      imm_select = IIMM;  // rs2 holds part of the instruction
                      // TODO CHECK R bit for valid fmt combinations
                      // determine source format
                      unique case (instr.rvftype.rs2[21:20])
                        // Only process instruction if corresponding extension is active (static)
                        2'b00:   if (~G6LCCfg.RVFVec) illegal_bit = 1'b1;
                        2'b01:   if (~G6LCCfg.XF16ALTVec) illegal_bit = 1'b1;
                        2'b10:   if (~G6LCCfg.XF16Vec) illegal_bit = 1'b1;
                        2'b11:   if (~G6LCCfg.XF8Vec) illegal_bit = 1'b1;
                        default: illegal_bit = 1'b1;
                      endcase
                    end
                    default: illegal_bit = 1'b1;
                  endcase
                end
                5'b01101: begin
                  check_fprm = 1'b0;  // no rounding for sign-injection
                  cand.op = g6lc_core_pkg::VFSGNJ; // vfsgnj.vfmt - Vectorial FP Sign Injection
                end
                5'b01110: begin
                  check_fprm = 1'b0;  // no rounding for sign-injection
                  cand.op = g6lc_core_pkg::VFSGNJN; // vfsgnjn.vfmt - Vectorial FP Negated Sign Injection
                end
                5'b01111: begin
                  check_fprm = 1'b0;  // no rounding for sign-injection
                  cand.op = g6lc_core_pkg::VFSGNJX; // vfsgnjx.vfmt - Vectorial FP XORed Sign Injection
                end
                5'b10000: begin
                  check_fprm       = 1'b0;  // no rounding for comparisons
                  cand.op = g6lc_core_pkg::VFEQ;  // vfeq.vfmt - Vectorial FP Equality
                end
                5'b10001: begin
                  check_fprm       = 1'b0;  // no rounding for comparisons
                  cand.op = g6lc_core_pkg::VFNE;  // vfne.vfmt - Vectorial FP Non-Equality
                end
                5'b10010: begin
                  check_fprm       = 1'b0;  // no rounding for comparisons
                  cand.op = g6lc_core_pkg::VFLT;  // vfle.vfmt - Vectorial FP Less Than
                end
                5'b10011: begin
                  check_fprm = 1'b0;  // no rounding for comparisons
                  cand.op = g6lc_core_pkg::VFGE;  // vfge.vfmt - Vectorial FP Greater or Equal
                end
                5'b10100: begin
                  check_fprm       = 1'b0;  // no rounding for comparisons
                  cand.op = g6lc_core_pkg::VFLE;  // vfle.vfmt - Vectorial FP Less or Equal
                end
                5'b10101: begin
                  check_fprm       = 1'b0;  // no rounding for comparisons
                  cand.op = g6lc_core_pkg::VFGT;  // vfgt.vfmt - Vectorial FP Greater Than
                end
                5'b11000: begin
                  cand.op  = g6lc_core_pkg::VFCPKAB_S; // vfcpka/b.vfmt.s - Vectorial FP Cast-and-Pack from 2x FP32, lowest 4 entries
                  imm_select = SIMM;  // rd into result field (upper bits don't matter)
                  if (~G6LCCfg.RVF)
                    illegal_bit = 1'b1;  // if we don't support RVF, we can't cast from FP32
                  // check destination format
                  unique case (instr.rvftype.vfmt)
                    // Only process instruction if corresponding extension is active and FLEN suffices (static)
                    2'b00: begin
                      if (~G6LCCfg.RVFVec)
                        illegal_bit = 1'b1;  // destination vector not supported
                      if (instr.rvftype.repl)
                        illegal_bit = 1'b1;  // no entries 2/3 in vector of 2 fp32
                    end
                    2'b01: begin
                      if (~G6LCCfg.XF16ALTVec)
                        illegal_bit = 1'b1;  // destination vector not supported
                    end
                    2'b10: begin
                      if (~G6LCCfg.XF16Vec)
                        illegal_bit = 1'b1;  // destination vector not supported
                    end
                    2'b11: begin
                      if (~G6LCCfg.XF8Vec)
                        illegal_bit = 1'b1;  // destination vector not supported
                    end
                    default: illegal_bit = 1'b1;
                  endcase
                end
                5'b11001: begin
                  cand.op  = g6lc_core_pkg::VFCPKCD_S; // vfcpkc/d.vfmt.s - Vectorial FP Cast-and-Pack from 2x FP32, second 4 entries
                  imm_select = SIMM;  // rd into result field (upper bits don't matter)
                  if (~G6LCCfg.RVF)
                    illegal_bit = 1'b1;  // if we don't support RVF, we can't cast from FP32
                  // check destination format
                  unique case (instr.rvftype.vfmt)
                    // Only process instruction if corresponding extension is active and FLEN suffices (static)
                    2'b00:   illegal_bit = 1'b1;  // no entries 4-7 in vector of 2 FP32
                    2'b01:   illegal_bit = 1'b1;  // no entries 4-7 in vector of 4 FP16ALT
                    2'b10:   illegal_bit = 1'b1;  // no entries 4-7 in vector of 4 FP16
                    2'b11: begin
                      if (~G6LCCfg.XF8Vec)
                        illegal_bit = 1'b1;  // destination vector not supported
                    end
                    default: illegal_bit = 1'b1;
                  endcase
                end
                5'b11010: begin
                  cand.op  = g6lc_core_pkg::VFCPKAB_D; // vfcpka/b.vfmt.d - Vectorial FP Cast-and-Pack from 2x FP64, lowest 4 entries
                  imm_select = SIMM;  // rd into result field (upper bits don't matter)
                  if (~G6LCCfg.RVD)
                    illegal_bit = 1'b1;  // if we don't support RVD, we can't cast from FP64
                  // check destination format
                  unique case (instr.rvftype.vfmt)
                    // Only process instruction if corresponding extension is active and FLEN suffices (static)
                    2'b00: begin
                      if (~G6LCCfg.RVFVec)
                        illegal_bit = 1'b1;  // destination vector not supported
                      if (instr.rvftype.repl)
                        illegal_bit = 1'b1;  // no entries 2/3 in vector of 2 fp32
                    end
                    2'b01: begin
                      if (~G6LCCfg.XF16ALTVec)
                        illegal_bit = 1'b1;  // destination vector not supported
                    end
                    2'b10: begin
                      if (~G6LCCfg.XF16Vec)
                        illegal_bit = 1'b1;  // destination vector not supported
                    end
                    2'b11: begin
                      if (~G6LCCfg.XF8Vec)
                        illegal_bit = 1'b1;  // destination vector not supported
                    end
                    default: illegal_bit = 1'b1;
                  endcase
                end
                5'b11011: begin
                  cand.op  = g6lc_core_pkg::VFCPKCD_D; // vfcpka/b.vfmt.d - Vectorial FP Cast-and-Pack from 2x FP64, second 4 entries
                  imm_select = SIMM;  // rd into result field (upper bits don't matter)
                  if (~G6LCCfg.RVD)
                    illegal_bit = 1'b1;  // if we don't support RVD, we can't cast from FP64
                  // check destination format
                  unique case (instr.rvftype.vfmt)
                    // Only process instruction if corresponding extension is active and FLEN suffices (static)
                    2'b00:   illegal_bit = 1'b1;  // no entries 4-7 in vector of 2 FP32
                    2'b01:   illegal_bit = 1'b1;  // no entries 4-7 in vector of 4 FP16ALT
                    2'b10:   illegal_bit = 1'b1;  // no entries 4-7 in vector of 4 FP16
                    2'b11: begin
                      if (~G6LCCfg.XF8Vec)
                        illegal_bit = 1'b1;  // destination vector not supported
                    end
                    default: illegal_bit = 1'b1;
                  endcase
                end
                default: illegal_bit = 1'b1;
              endcase

              // check format
              unique case (instr.rvftype.vfmt)
                // Only process instruction if corresponding extension is active (static)
                2'b00:   if (~G6LCCfg.RVFVec) illegal_bit = 1'b1;
                2'b01:   if (~G6LCCfg.XF16ALTVec) illegal_bit = 1'b1;
                2'b10:   if (~G6LCCfg.XF16Vec) illegal_bit = 1'b1;
                2'b11:   if (~G6LCCfg.XF8Vec) illegal_bit = 1'b1;
                default: illegal_bit = 1'b1;
              endcase

              // check disallowed replication
              if (~allow_replication & instr.rvftype.repl) illegal_bit = 1'b1;

              // check rounding mode
              if (check_fprm) begin
                frm_req = 1'b1;  // hyp8: frm_i legality deferred to g6lc_decode_s3
              end

            end else begin  // No vectorial FP enabled (static)
              illegal_bit = 1'b1;
            end

            // ---------------------------
            // Integer Reg-Reg Operations
            // ---------------------------
          end else begin
            if (G6LCCfg.RVB) begin
              cand.fu  = (instr.rtype.funct7 == 7'b000_0001 || ((instr.rtype.funct7 == 7'b000_0101) && !(instr.rtype.funct3[14]))) ? MULT : ALU;
            end else begin
              cand.fu = (instr.rtype.funct7 == 7'b000_0001) ? MULT : ALU;
            end
            cand.rs1 = instr.rtype.rs1;
            cand.rs2 = instr.rtype.rs2;
            cand.rd  = instr.rtype.rd;

            unique case ({
              instr.rtype.funct7, instr.rtype.funct3
            })
              {7'b000_0000, 3'b000} : cand.op = g6lc_core_pkg::ADD;  // Add
              {7'b010_0000, 3'b000} : cand.op = g6lc_core_pkg::SUB;  // Sub
              {7'b000_0000, 3'b010} : cand.op = g6lc_core_pkg::SLTS;  // Set Lower Than
              {
                7'b000_0000, 3'b011
              } :
              cand.op = g6lc_core_pkg::SLTU;  // Set Lower Than Unsigned
              {7'b000_0000, 3'b100} : cand.op = g6lc_core_pkg::XORL;  // Xor
              {7'b000_0000, 3'b110} : cand.op = g6lc_core_pkg::ORL;  // Or
              {7'b000_0000, 3'b111} : cand.op = g6lc_core_pkg::ANDL;  // And
              {7'b000_0000, 3'b001} : cand.op = g6lc_core_pkg::SLL;  // Shift Left Logical
              {7'b000_0000, 3'b101} : cand.op = g6lc_core_pkg::SRL;  // Shift Right Logical
              {7'b010_0000, 3'b101} : cand.op = g6lc_core_pkg::SRA;  // Shift Right Arithmetic
              // Multiplications
              {7'b000_0001, 3'b000} : cand.op = g6lc_core_pkg::MUL;
              {7'b000_0001, 3'b001} : cand.op = g6lc_core_pkg::MULH;
              {7'b000_0001, 3'b010} : cand.op = g6lc_core_pkg::MULHSU;
              {7'b000_0001, 3'b011} : cand.op = g6lc_core_pkg::MULHU;
              {7'b000_0001, 3'b100} : cand.op = g6lc_core_pkg::DIV;
              {7'b000_0001, 3'b101} : cand.op = g6lc_core_pkg::DIVU;
              {7'b000_0001, 3'b110} : cand.op = g6lc_core_pkg::REM;
              {7'b000_0001, 3'b111} : cand.op = g6lc_core_pkg::REMU;
              default: begin
                illegal_instr_non_bm = 1'b1;
              end
            endcase
            if (G6LCCfg.RVB) begin
              unique case ({
                instr.rtype.funct7, instr.rtype.funct3
              })
                //Logical with Negate
                {7'b010_0000, 3'b111} : cand.op = g6lc_core_pkg::ANDN;  // Andn
                {7'b010_0000, 3'b110} : cand.op = g6lc_core_pkg::ORN;  // Orn
                {7'b010_0000, 3'b100} : cand.op = g6lc_core_pkg::XNOR;  // Xnor
                //Shift and Add (Bitmanip)
                {7'b001_0000, 3'b010} : cand.op = g6lc_core_pkg::SH1ADD;  // Sh1add
                {7'b001_0000, 3'b100} : cand.op = g6lc_core_pkg::SH2ADD;  // Sh2add
                {7'b001_0000, 3'b110} : cand.op = g6lc_core_pkg::SH3ADD;  // Sh3add
                // Integer maximum/minimum
                {7'b000_0101, 3'b110} : cand.op = g6lc_core_pkg::MAX;  // max
                {7'b000_0101, 3'b111} : cand.op = g6lc_core_pkg::MAXU;  // maxu
                {7'b000_0101, 3'b100} : cand.op = g6lc_core_pkg::MIN;  // min
                {7'b000_0101, 3'b101} : cand.op = g6lc_core_pkg::MINU;  // minu
                // Single bit instructions
                {7'b010_0100, 3'b001} : cand.op = g6lc_core_pkg::BCLR;  // bclr
                {7'b010_0100, 3'b101} : cand.op = g6lc_core_pkg::BEXT;  // bext
                {7'b011_0100, 3'b001} : cand.op = g6lc_core_pkg::BINV;  // binv
                {7'b001_0100, 3'b001} : cand.op = g6lc_core_pkg::BSET;  // bset
                // Carry-Less-Multiplication (clmul, clmulh, clmulr)
                {7'b000_0101, 3'b001} : cand.op = g6lc_core_pkg::CLMUL;  // clmul
                {7'b000_0101, 3'b011} : cand.op = g6lc_core_pkg::CLMULH;  // clmulh
                {7'b000_0101, 3'b010} : cand.op = g6lc_core_pkg::CLMULR;  // clmulr
                // Bitwise Shifting
                {7'b011_0000, 3'b001} : cand.op = g6lc_core_pkg::ROL;  // rol
                {7'b011_0000, 3'b101} : cand.op = g6lc_core_pkg::ROR;  // ror
                {
                  7'b000_0100, 3'b111
                } : begin
                  if (G6LCCfg.ZKN) cand.op = g6lc_core_pkg::PACK_H;  //packh
                  else illegal_instr_bm = 1'b1;
                end
                {
                  7'b001_0100, 3'b100
                } : begin
                  if (G6LCCfg.ZKN) cand.op = g6lc_core_pkg::XPERM8;  // xperm8
                  else illegal_instr_bm = 1'b1;
                end
                {
                  7'b001_0100, 3'b010
                } : begin
                  if (G6LCCfg.ZKN) cand.op = g6lc_core_pkg::XPERM4;  // xperm4
                  else illegal_instr_bm = 1'b1;
                end
                // Zero Extend Op RV32 encoding
                {
                  7'b000_0100, 3'b100
                } : begin
                  if (!G6LCCfg.IS_XLEN64 && instr.instr[24:20] == 5'b00000)
                    cand.op = g6lc_core_pkg::ZEXTH;  // Zero Extend Op RV32 encoding
                  else if (G6LCCfg.ZKN) cand.op = g6lc_core_pkg::PACK;  // pack
                  else illegal_instr_bm = 1'b1;
                end
                {
                  7'b001_1001, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES64ES;  // aes64es
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b001_1011, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES64ESM;  // aes64esm
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b011_1111, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES64KS2;  // aes64ks2
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b0010001, 3'b000
                }, {
                  7'b0110001, 3'b000
                }, {
                  7'b1010001, 3'b000
                }, {
                  7'b1110001, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES32ESI;  // aes32esi
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b0010011, 3'b000
                }, {
                  7'b0110011, 3'b000
                }, {
                  7'b1010011, 3'b000
                }, {
                  7'b1110011, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES32ESMI;  // aes32esmi
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b0010101, 3'b000
                }, {
                  7'b0110101, 3'b000
                }, {
                  7'b1010101, 3'b000
                }, {
                  7'b1110101, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES32DSI;  // aes32dsi
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b0010111, 3'b000
                }, {
                  7'b0110111, 3'b000
                }, {
                  7'b1010111, 3'b000
                }, {
                  7'b1110111, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES32DSMI;  // aes32dsmi
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b001_1101, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES64DS;  // aes64ds
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b001_1111, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::AES64DSM;  // aes64dsm
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b010_1110, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::SHA512SIG0H;  // sha512sig0h
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b010_1010, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::SHA512SIG0L;  // sha512sig0l
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b010_1111, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::SHA512SIG1H;  // sha512sig1h
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b010_1011, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::SHA512SIG1L;  // sha512sig1l
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b010_1000, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::SHA512SUM0R;  // sha512sum0r
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                {
                  7'b010_1001, 3'b000
                } : begin
                  if (G6LCCfg.ZKN) begin
                    cand.op = g6lc_core_pkg::SHA512SUM1R;  // sha512sum1r
                    cand.fu = AES;
                  end else illegal_instr_bm = 1'b1;
                end
                default: begin
                  illegal_instr_bm = 1'b1;
                end
              endcase
            end
            if (G6LCCfg.RVZiCond) begin
              unique case ({
                instr.rtype.funct7, instr.rtype.funct3
              })
                //Conditional move
                {7'b000_0111, 3'b101} : cand.op = g6lc_core_pkg::CZERO_EQZ;  // czero.eqz
                {7'b000_0111, 3'b111} : cand.op = g6lc_core_pkg::CZERO_NEZ;  // czero.nez
                default: begin
                  illegal_instr_zic = 1'b1;
                end
              endcase
            end
            //VCS coverage on
            unique case ({
              G6LCCfg.RVB, G6LCCfg.RVZiCond
            })
              2'b00:   illegal_bit = illegal_instr_non_bm;
              2'b01:   illegal_bit = illegal_instr_non_bm & illegal_instr_zic;
              2'b10:   illegal_bit = illegal_instr_non_bm & illegal_instr_bm;
              2'b11:   illegal_bit = illegal_instr_non_bm & illegal_instr_bm & illegal_instr_zic;
              default: ;  // TODO: Check that default case is not synthesized.
            endcase
          end
        end

        // --------------------------
        // 32bit Reg-Reg Operations
        // --------------------------
        riscv::OpcodeOp32: begin
          cand.fu  = (instr.rtype.funct7 == 7'b000_0001) ? MULT : ALU;
          cand.rs1 = instr.rtype.rs1;
          cand.rs2 = instr.rtype.rs2;
          cand.rd  = instr.rtype.rd;
          if (G6LCCfg.IS_XLEN64) begin
            unique case ({
              instr.rtype.funct7, instr.rtype.funct3
            })
              {7'b000_0000, 3'b000} : cand.op = g6lc_core_pkg::ADDW;  // addw
              {7'b010_0000, 3'b000} : cand.op = g6lc_core_pkg::SUBW;  // subw
              {7'b000_0000, 3'b001} : cand.op = g6lc_core_pkg::SLLW;  // sllw
              {7'b000_0000, 3'b101} : cand.op = g6lc_core_pkg::SRLW;  // srlw
              {7'b010_0000, 3'b101} : cand.op = g6lc_core_pkg::SRAW;  // sraw
              // Multiplications
              {7'b000_0001, 3'b000} : cand.op = g6lc_core_pkg::MULW;
              {7'b000_0001, 3'b100} : cand.op = g6lc_core_pkg::DIVW;
              {7'b000_0001, 3'b101} : cand.op = g6lc_core_pkg::DIVUW;
              {7'b000_0001, 3'b110} : cand.op = g6lc_core_pkg::REMW;
              {7'b000_0001, 3'b111} : cand.op = g6lc_core_pkg::REMUW;
              default: illegal_instr_non_bm = 1'b1;
            endcase
            if (G6LCCfg.RVB) begin
              unique case ({
                instr.rtype.funct7, instr.rtype.funct3
              })
                // Shift with Add (Unsigned Word)
                {7'b001_0000, 3'b010} : cand.op = g6lc_core_pkg::SH1ADDUW;  // sh1add.uw
                {7'b001_0000, 3'b100} : cand.op = g6lc_core_pkg::SH2ADDUW;  // sh2add.uw
                {7'b001_0000, 3'b110} : cand.op = g6lc_core_pkg::SH3ADDUW;  // sh3add.uw
                // Unsigned word Op's
                {7'b000_0100, 3'b000} : cand.op = g6lc_core_pkg::ADDUW;  // add.uw
                // Bitwise Shifting
                {7'b011_0000, 3'b001} : cand.op = g6lc_core_pkg::ROLW;  // rolw
                {7'b011_0000, 3'b101} : cand.op = g6lc_core_pkg::RORW;  // rorw
                {
                  7'b000_0100, 3'b100
                } : begin
                  if (instr.instr[24:20] == 5'b00000)
                    cand.op = g6lc_core_pkg::ZEXTH;  // Zero Extend Op RV64 encoding
                  else if (G6LCCfg.ZKN) cand.op = g6lc_core_pkg::PACK_W;  // packw
                  else illegal_instr_bm = 1'b1;
                end
                default: illegal_instr_bm = 1'b1;
              endcase
              illegal_bit = illegal_instr_non_bm & illegal_instr_bm;
            end else begin
              illegal_bit = illegal_instr_non_bm;
            end
          end else illegal_bit = 1'b1;
        end
        // --------------------------------
        // Reg-Immediate Operations
        // --------------------------------
        riscv::OpcodeOpImm: begin
          cand.fu = ALU;
          imm_select = IIMM;
          cand.rs1 = instr.itype.rs1;
          cand.rd = instr.itype.rd;
          // Zicbop PREFETCH.{I,R,W}: ORI HINT with rd=x0, imm[4:0]=0;
          // imm[11:5] ∈ {0,1,3}. itype.imm is [31:20] so use [24:20]/[31:25].
          // Execute as architectural NOP (ADD x0,x0,x0).
          if (G6LCCfg.RVZiCbop &&
              instr.itype.funct3 == 3'b110 &&
              instr.itype.rd == 5'b0 &&
              instr.itype.imm[24:20] == 5'b0 &&
              (instr.itype.imm[31:25] inside {7'd0, 7'd1, 7'd3})) begin
            cand.op  = g6lc_core_pkg::ADD;
            cand.rs1 = '0;
            cand.rd  = '0;
            imm_select        = NOIMM;
          end else begin
          unique case (instr.itype.funct3)
            3'b000: cand.op = g6lc_core_pkg::ADD;  // Add Immediate
            3'b010: cand.op = g6lc_core_pkg::SLTS;  // Set to one if Lower Than Immediate
            3'b011:
            cand.op = g6lc_core_pkg::SLTU;  // Set to one if Lower Than Immediate Unsigned
            3'b100: cand.op = g6lc_core_pkg::XORL;  // Exclusive Or with Immediate
            3'b110: cand.op = g6lc_core_pkg::ORL;  // Or with Immediate
            3'b111: cand.op = g6lc_core_pkg::ANDL;  // And with Immediate

            3'b001: begin
              cand.op = g6lc_core_pkg::SLL;  // Shift Left Logical by Immediate
              if (instr.instr[31:26] != 6'b0) illegal_instr_non_bm = 1'b1;
              if (instr.instr[25] != 1'b0 && G6LCCfg.IS_XLEN32) illegal_instr_non_bm = 1'b1;
            end

            3'b101: begin
              if (instr.instr[31:26] == 6'b0)
                cand.op = g6lc_core_pkg::SRL;  // Shift Right Logical by Immediate
              else if (instr.instr[31:26] == 6'b010_000)
                cand.op = g6lc_core_pkg::SRA;  // Shift Right Arithmetically by Immediate
              else illegal_instr_non_bm = 1'b1;
              if (instr.instr[25] != 1'b0 && G6LCCfg.IS_XLEN32) illegal_instr_non_bm = 1'b1;
            end
          endcase
          end
          if (G6LCCfg.RVB) begin
            unique case (instr.itype.funct3)
              3'b001: begin
                if (instr.instr[31:25] == 7'b0110000) begin
                  if (instr.instr[24:20] == 5'b00100) cand.op = g6lc_core_pkg::SEXTB;
                  else if (instr.instr[24:20] == 5'b00101) cand.op = g6lc_core_pkg::SEXTH;
                  else if (instr.instr[24:20] == 5'b00010) cand.op = g6lc_core_pkg::CPOP;
                  else if (instr.instr[24:20] == 5'b00000) cand.op = g6lc_core_pkg::CLZ;
                  else if (instr.instr[24:20] == 5'b00001) cand.op = g6lc_core_pkg::CTZ;
                  else illegal_instr_bm = 1'b1;
                end else if (G6LCCfg.IS_XLEN64 && instr.instr[31:26] == 6'b010010)
                  cand.op = g6lc_core_pkg::BCLRI;
                else if (G6LCCfg.IS_XLEN32 && instr.instr[31:25] == 7'b0100100)
                  cand.op = g6lc_core_pkg::BCLRI;
                else if (G6LCCfg.IS_XLEN64 && instr.instr[31:26] == 6'b011010)
                  cand.op = g6lc_core_pkg::BINVI;
                else if (G6LCCfg.IS_XLEN32 && instr.instr[31:25] == 7'b0110100)
                  cand.op = g6lc_core_pkg::BINVI;
                else if (G6LCCfg.IS_XLEN64 && instr.instr[31:26] == 6'b001010)
                  cand.op = g6lc_core_pkg::BSETI;
                else if (G6LCCfg.IS_XLEN32 && instr.instr[31:25] == 7'b0010100)
                  cand.op = g6lc_core_pkg::BSETI;
                else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000010001111)
                  cand.op = g6lc_core_pkg::ZIP;
                else if (G6LCCfg.ZKN && instr.instr[31:24] == 8'b00110001) begin
                  cand.op = g6lc_core_pkg::AES64KS1I;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b001100000000) begin
                  cand.op = g6lc_core_pkg::AES64IM;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000100000010) begin
                  cand.op = g6lc_core_pkg::SHA256SIG0;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000100000011) begin
                  cand.op = g6lc_core_pkg::SHA256SIG1;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000100000000) begin
                  cand.op = g6lc_core_pkg::SHA256SUM0;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000100000001) begin
                  cand.op = g6lc_core_pkg::SHA256SUM1;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000100000110) begin
                  cand.op = g6lc_core_pkg::SHA512SIG0;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000100000111) begin
                  cand.op = g6lc_core_pkg::SHA512SIG1;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000100000100) begin
                  cand.op = g6lc_core_pkg::SHA512SUM0;
                  cand.fu = AES;
                end else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000100000101) begin
                  cand.op = g6lc_core_pkg::SHA512SUM1;
                  cand.fu = AES;
                end else illegal_instr_bm = 1'b1;
              end
              3'b101: begin
                if (instr.instr[31:20] == 12'b001010000111) cand.op = g6lc_core_pkg::ORCB;
                else if (G6LCCfg.IS_XLEN64 && instr.instr[31:20] == 12'b011010111000)
                  cand.op = g6lc_core_pkg::REV8;
                else if (instr.instr[31:20] == 12'b011010011000)
                  cand.op = g6lc_core_pkg::REV8;
                else if (G6LCCfg.IS_XLEN64 && instr.instr[31:26] == 6'b010_010)
                  cand.op = g6lc_core_pkg::BEXTI;
                else if (G6LCCfg.IS_XLEN32 && instr.instr[31:25] == 7'b010_0100)
                  cand.op = g6lc_core_pkg::BEXTI;
                else if (G6LCCfg.IS_XLEN64 && instr.instr[31:26] == 6'b011_000)
                  cand.op = g6lc_core_pkg::RORI;
                else if (G6LCCfg.IS_XLEN32 && instr.instr[31:25] == 7'b011_0000)
                  cand.op = g6lc_core_pkg::RORI;
                else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b011010000111)
                  cand.op = g6lc_core_pkg::BREV8;
                else if (G6LCCfg.ZKN && instr.instr[31:20] == 12'b000010001111)
                  cand.op = g6lc_core_pkg::UNZIP;
                else illegal_instr_bm = 1'b1;
              end
              default: illegal_instr_bm = 1'b1;
            endcase
            illegal_bit = illegal_instr_non_bm & illegal_instr_bm;
          end else begin
            illegal_bit = illegal_instr_non_bm;
          end
        end

        // --------------------------------
        // 32 bit Reg-Immediate Operations
        // --------------------------------
        riscv::OpcodeOpImm32: begin
          cand.fu = ALU;
          imm_select = IIMM;
          cand.rs1 = instr.itype.rs1;
          cand.rd = instr.itype.rd;
          if (G6LCCfg.IS_XLEN64) begin
            unique case (instr.itype.funct3)
              3'b000:  cand.op = g6lc_core_pkg::ADDW;  // Add Immediate
              3'b001: begin
                cand.op = g6lc_core_pkg::SLLW;  // Shift Left Logical by Immediate
                if (instr.instr[31:25] != 7'b0) illegal_instr_non_bm = 1'b1;
              end
              3'b101: begin
                if (instr.instr[31:25] == 7'b0)
                  cand.op = g6lc_core_pkg::SRLW;  // Shift Right Logical by Immediate
                else if (instr.instr[31:25] == 7'b010_0000)
                  cand.op = g6lc_core_pkg::SRAW;  // Shift Right Arithmetically by Immediate
                else illegal_instr_non_bm = 1'b1;
              end
              default: illegal_instr_non_bm = 1'b1;
            endcase
            if (G6LCCfg.RVB) begin
              unique case (instr.itype.funct3)
                3'b001: begin
                  if (instr.instr[31:25] == 7'b0110000) begin
                    if (instr.instr[24:20] == 5'b00010) cand.op = g6lc_core_pkg::CPOPW;
                    else if (instr.instr[24:20] == 5'b00000) cand.op = g6lc_core_pkg::CLZW;
                    else if (instr.instr[24:20] == 5'b00001) cand.op = g6lc_core_pkg::CTZW;
                    else illegal_instr_bm = 1'b1;
                  end else if (instr.instr[31:26] == 6'b000010) begin
                    cand.op = g6lc_core_pkg::SLLIUW; // Shift Left Logic by Immediate (Unsigned Word)
                  end else illegal_instr_bm = 1'b1;
                end
                3'b101: begin
                  if (instr.instr[31:25] == 7'b011_0000) cand.op = g6lc_core_pkg::RORIW;
                  else illegal_instr_bm = 1'b1;
                end
                default: illegal_instr_bm = 1'b1;
              endcase
              illegal_bit = illegal_instr_non_bm & illegal_instr_bm;
            end else begin
              illegal_bit = illegal_instr_non_bm;
            end

          end else illegal_bit = 1'b1;
        end
        // --------------------------------
        // LSU
        // --------------------------------
        riscv::OpcodeStore: begin
          cand.fu = STORE;
          imm_select = SIMM;
          cand.rs1 = instr.stype.rs1;
          cand.rs2 = instr.stype.rs2;
          // determine store size
          unique case (instr.stype.funct3)
            3'b000: cand.op = g6lc_core_pkg::SB;
            3'b001: cand.op = g6lc_core_pkg::SH;
            3'b010: cand.op = g6lc_core_pkg::SW;
            3'b011:
            if (G6LCCfg.IS_XLEN64) cand.op = g6lc_core_pkg::SD;
            else illegal_bit = 1'b1;
            default: illegal_bit = 1'b1;
          endcase
          if (G6LCCfg.RVH) begin
            tinst = {7'b0, instr.stype.rs2, 5'b0, instr.stype.funct3, 5'b0, instr.stype.opcode};
            tinst[1] = is_compressed_i ? 1'b0 : 'b1;
          end
        end

        riscv::OpcodeLoad: begin
          cand.fu = LOAD;
          imm_select = IIMM;
          cand.rs1 = instr.itype.rs1;
          cand.rd = instr.itype.rd;
          // determine load size and signed type
          unique case (instr.itype.funct3)
            3'b000: cand.op = g6lc_core_pkg::LB;
            3'b001: cand.op = g6lc_core_pkg::LH;
            3'b010: cand.op = g6lc_core_pkg::LW;
            3'b100: cand.op = g6lc_core_pkg::LBU;
            3'b101: cand.op = g6lc_core_pkg::LHU;
            3'b110:
            if (G6LCCfg.IS_XLEN64) cand.op = g6lc_core_pkg::LWU;
            else illegal_bit = 1'b1;
            3'b011:
            if (G6LCCfg.IS_XLEN64) cand.op = g6lc_core_pkg::LD;
            else illegal_bit = 1'b1;
            default: illegal_bit = 1'b1;
          endcase
          if (G6LCCfg.RVH) begin
            tinst = {17'b0, instr.itype.funct3, instr.itype.rd, instr.itype.opcode};
            tinst[1] = is_compressed_i ? 1'b0 : 'b1;
          end
        end

        // --------------------------------
        // Floating-Point Load/store
        // --------------------------------
        riscv::OpcodeStoreFp: begin
          if (G6LCCfg.FpPresent) begin // only generate decoder if FP extensions are enabled (static)
              fp_hit = 1'b1;  // hyp8: fs_i/vfs_i/v_i legality deferred to g6lc_decode_s3
            cand.fu = STORE;
            imm_select = SIMM;
            cand.rs1 = instr.stype.rs1;
            cand.rs2 = instr.stype.rs2;
            // determine store size
            unique case (instr.stype.funct3)
              // Only process instruction if corresponding extension is active (static)
              3'b000:
              if (G6LCCfg.XF8) cand.op = g6lc_core_pkg::FSB;
              else illegal_bit = 1'b1;
              3'b001:
              if (G6LCCfg.XF16 | G6LCCfg.XF16ALT) cand.op = g6lc_core_pkg::FSH;
              else illegal_bit = 1'b1;
              3'b010:
              if (G6LCCfg.RVF) cand.op = g6lc_core_pkg::FSW;
              else illegal_bit = 1'b1;
              3'b011:
              if (G6LCCfg.RVD) cand.op = g6lc_core_pkg::FSD;
              else illegal_bit = 1'b1;
              default: illegal_bit = 1'b1;
            endcase
            if (G6LCCfg.RVH) begin
              tinst = {7'b0, instr.stype.rs2, 5'b0, instr.stype.funct3, 5'b0, instr.stype.opcode};
              tinst[1] = is_compressed_i ? 1'b0 : 'b1;
            end
          end else illegal_bit = 1'b1;
        end

        riscv::OpcodeLoadFp: begin
          if (G6LCCfg.FpPresent) begin // only generate decoder if FP extensions are enabled (static)
              fp_hit = 1'b1;  // hyp8: fs_i/vfs_i/v_i legality deferred to g6lc_decode_s3
            cand.fu = LOAD;
            imm_select = IIMM;
            cand.rs1 = instr.itype.rs1;
            cand.rd = instr.itype.rd;
            // determine load size
            unique case (instr.itype.funct3)
              // Only process instruction if corresponding extension is active (static)
              3'b000:
              if (G6LCCfg.XF8) cand.op = g6lc_core_pkg::FLB;
              else illegal_bit = 1'b1;
              3'b001:
              if (G6LCCfg.XF16 | G6LCCfg.XF16ALT) cand.op = g6lc_core_pkg::FLH;
              else illegal_bit = 1'b1;
              3'b010:
              if (G6LCCfg.RVF) cand.op = g6lc_core_pkg::FLW;
              else illegal_bit = 1'b1;
              3'b011:
              if (G6LCCfg.RVD) cand.op = g6lc_core_pkg::FLD;
              else illegal_bit = 1'b1;
              default: illegal_bit = 1'b1;
            endcase
            if (G6LCCfg.RVH) begin
              tinst = {17'b0, instr.itype.funct3, instr.itype.rd, instr.itype.opcode};
              tinst[1] = is_compressed_i ? 1'b0 : 'b1;
            end
          end else illegal_bit = 1'b1;
        end

        // ----------------------------------
        // Floating-Point Reg-Reg Operations
        // ----------------------------------
        riscv::OpcodeMadd, riscv::OpcodeMsub, riscv::OpcodeNmsub, riscv::OpcodeNmadd: begin
          if (G6LCCfg.FpPresent) begin // only generate decoder if FP extensions are enabled (static)
              fp_hit = 1'b1;  // hyp8: fs_i/vfs_i/v_i legality deferred to g6lc_decode_s3
            cand.fu  = FPU;
            cand.rs1 = instr.r4type.rs1;
            cand.rs2 = instr.r4type.rs2;
            cand.rd  = instr.r4type.rd;
            imm_select        = RS3;  // rs3 into result field
            check_fprm        = 1'b1;
            // select the correct fused operation
            unique case (instr.r4type.opcode)
              default: cand.op = g6lc_core_pkg::FMADD;  // fmadd.fmt - FP Fused multiply-add
              riscv::OpcodeMsub:
              cand.op = g6lc_core_pkg::FMSUB;  // fmsub.fmt - FP Fused multiply-subtract
              riscv::OpcodeNmsub:
              cand.op = g6lc_core_pkg::FNMSUB; // fnmsub.fmt - FP Negated fused multiply-subtract
              riscv::OpcodeNmadd:
              cand.op = g6lc_core_pkg::FNMADD;  // fnmadd.fmt - FP Negated fused multiply-add
            endcase

            // determine fp format
            unique case (instr.r4type.funct2)
              // Only process instruction if corresponding extension is active (static)
              2'b00:   if (~G6LCCfg.RVF) illegal_bit = 1'b1;
              2'b01:   if (~G6LCCfg.RVD) illegal_bit = 1'b1;
              2'b10:   if (~G6LCCfg.XF16 & ~G6LCCfg.XF16ALT) illegal_bit = 1'b1;
              2'b11:   if (~G6LCCfg.XF8) illegal_bit = 1'b1;
              default: illegal_bit = 1'b1;
            endcase

            // check rounding mode
            if (check_fprm) begin
              unique case (instr.rftype.rm) inside
                [3'b000 : 3'b100]: ;  //legal rounding modes
                3'b101: begin  // Alternative Half-Precision encoded as fmt=10 and rm=101
                  if (~G6LCCfg.XF16ALT || instr.rftype.fmt != 2'b10) illegal_bit = 1'b1;
                  frm_req = 1'b1;  // hyp8: frm_i legality deferred to g6lc_decode_s3
                end
                3'b111: begin
                  // rounding mode from frm csr
                  frm_req = 1'b1;  // hyp8: frm_i legality deferred to g6lc_decode_s3
                end
                default:           illegal_bit = 1'b1;
              endcase
            end
          end else begin
            illegal_bit = 1'b1;
          end
        end

        riscv::OpcodeOpFp: begin
          if (G6LCCfg.FpPresent) begin // only generate decoder if FP extensions are enabled (static)
              fp_hit = 1'b1;  // hyp8: fs_i/vfs_i/v_i legality deferred to g6lc_decode_s3
            cand.fu  = FPU;
            cand.rs1 = instr.rftype.rs1;
            cand.rs2 = instr.rftype.rs2;
            cand.rd  = instr.rftype.rd;
            check_fprm        = 1'b1;
            // decode FP instruction
            unique case (instr.rftype.funct5)
              5'b00000: begin
                cand.op  = g6lc_core_pkg::FADD;  // fadd.fmt - FP Addition
                cand.rs1 = '0;  // Operand A is set to 0
                cand.rs2 = instr.rftype.rs1;  // Operand B is set to rs1
                imm_select        = IIMM;  // Operand C is set to rs2
              end
              5'b00001: begin
                cand.op  = g6lc_core_pkg::FSUB;  // fsub.fmt - FP Subtraction
                cand.rs1 = '0;  // Operand A is set to 0
                cand.rs2 = instr.rftype.rs1;  // Operand B is set to rs1
                imm_select        = IIMM;  // Operand C is set to rs2
              end
              5'b00010: cand.op = g6lc_core_pkg::FMUL;  // fmul.fmt - FP Multiplication
              5'b00011: cand.op = g6lc_core_pkg::FDIV;  // fdiv.fmt - FP Division
              5'b01011: begin
                cand.op = g6lc_core_pkg::FSQRT;  // fsqrt.fmt - FP Square Root
                // rs2 must be zero
                if (instr.rftype.rs2 != 5'b00000) illegal_bit = 1'b1;
              end
              5'b00100: begin
                cand.op = g6lc_core_pkg::FSGNJ;  // fsgn{j[n]/jx}.fmt - FP Sign Injection
                check_fprm       = 1'b0;  // instruction encoded in rm, do the check here
                if (G6LCCfg.XF16ALT) begin        // FP16ALT instructions encoded in rm separately (static)
                  if (!(instr.rftype.rm inside {[3'b000 : 3'b010], [3'b100 : 3'b110]}))
                    illegal_bit = 1'b1;
                end else begin
                  if (!(instr.rftype.rm inside {[3'b000 : 3'b010]})) illegal_bit = 1'b1;
                end
              end
              5'b00101: begin
                cand.op = g6lc_core_pkg::FMIN_MAX;  // fmin/fmax.fmt - FP Minimum / Maximum
                check_fprm       = 1'b0;  // instruction encoded in rm, do the check here
                if (G6LCCfg.XF16ALT) begin           // FP16ALT instructions encoded in rm separately (static)
                  if (!(instr.rftype.rm inside {[3'b000 : 3'b001], [3'b100 : 3'b101]}))
                    illegal_bit = 1'b1;
                end else begin
                  if (!(instr.rftype.rm inside {[3'b000 : 3'b001]})) illegal_bit = 1'b1;
                end
              end
              5'b01000: begin
                cand.op = g6lc_core_pkg::FCVT_F2F;  // fcvt.fmt.fmt - FP to FP Conversion
                cand.rs2 = instr.rvftype.rs1; // tie rs2 to rs1 to be safe (vectors use rs2)
                imm_select = IIMM;  // rs2 holds part of the instruction
                if (|instr.rftype.rs2[24:23])
                  illegal_bit = 1'b1;  // bits [22:20] used, other bits must be 0
                // check source format
                unique case (instr.rftype.rs2[22:20])
                  // Only process instruction if corresponding extension is active (static)
                  3'b000:  if (~G6LCCfg.RVF) illegal_bit = 1'b1;
                  3'b001:  if (~G6LCCfg.RVD) illegal_bit = 1'b1;
                  3'b010:  if (~G6LCCfg.XF16) illegal_bit = 1'b1;
                  3'b110:  if (~G6LCCfg.XF16ALT) illegal_bit = 1'b1;
                  3'b011:  if (~G6LCCfg.XF8) illegal_bit = 1'b1;
                  default: illegal_bit = 1'b1;
                endcase
              end
              5'b10100: begin
                cand.op = g6lc_core_pkg::FCMP;  // feq/flt/fle.fmt - FP Comparisons
                check_fprm       = 1'b0;  // instruction encoded in rm, do the check here
                if (G6LCCfg.XF16ALT) begin       // FP16ALT instructions encoded in rm separately (static)
                  if (!(instr.rftype.rm inside {[3'b000 : 3'b010], [3'b100 : 3'b110]}))
                    illegal_bit = 1'b1;
                end else begin
                  if (!(instr.rftype.rm inside {[3'b000 : 3'b010]})) illegal_bit = 1'b1;
                end
              end
              5'b11000: begin
                cand.op = g6lc_core_pkg::FCVT_F2I;  // fcvt.ifmt.fmt - FP to Int Conversion
                imm_select       = IIMM;  // rs2 holds part of the instruction
                if (|instr.rftype.rs2[24:22])
                  illegal_bit = 1'b1;  // bits [21:20] used, other bits must be 0
              end
              5'b11010: begin
                cand.op = g6lc_core_pkg::FCVT_I2F;  // fcvt.fmt.ifmt - Int to FP Conversion
                imm_select       = IIMM;  // rs2 holds part of the instruction
                if (|instr.rftype.rs2[24:22])
                  illegal_bit = 1'b1;  // bits [21:20] used, other bits must be 0
              end
              5'b11100: begin
                cand.rs2 = instr.rftype.rs1; // set rs2 = rs1 so we can map FMV to SGNJ in the unit
                check_fprm = 1'b0;  // instruction encoded in rm, do the check here
                if (instr.rftype.rm == 3'b000 || (G6LCCfg.XF16ALT && instr.rftype.rm == 3'b100)) // FP16ALT has separate encoding
                  cand.op = g6lc_core_pkg::FMV_F2X;  // fmv.ifmt.fmt - FPR to GPR Move
                else if (instr.rftype.rm == 3'b001 || (G6LCCfg.XF16ALT && instr.rftype.rm == 3'b101)) // FP16ALT has separate encoding
                  cand.op = g6lc_core_pkg::FCLASS;  // fclass.fmt - FP Classify
                else illegal_bit = 1'b1;
                // rs2 must be zero
                if (instr.rftype.rs2 != 5'b00000) illegal_bit = 1'b1;
              end
              5'b11110: begin
                cand.op = g6lc_core_pkg::FMV_X2F;  // fmv.fmt.ifmt - GPR to FPR Move
                cand.rs2 = instr.rftype.rs1; // set rs2 = rs1 so we can map FMV to SGNJ in the unit
                check_fprm = 1'b0;  // instruction encoded in rm, do the check here
                if (!(instr.rftype.rm == 3'b000 || (G6LCCfg.XF16ALT && instr.rftype.rm == 3'b100)))
                  illegal_bit = 1'b1;
                // rs2 must be zero
                if (instr.rftype.rs2 != 5'b00000) illegal_bit = 1'b1;
              end
              default:  illegal_bit = 1'b1;
            endcase

            // check format
            unique case (instr.rftype.fmt)
              // Only process instruction if corresponding extension is active (static)
              2'b00:   if (~G6LCCfg.RVF) illegal_bit = 1'b1;
              2'b01:   if (~G6LCCfg.RVD) illegal_bit = 1'b1;
              2'b10:   if (~G6LCCfg.XF16 & ~G6LCCfg.XF16ALT) illegal_bit = 1'b1;
              2'b11:   if (~G6LCCfg.XF8) illegal_bit = 1'b1;
              default: illegal_bit = 1'b1;
            endcase

            // check rounding mode
            if (check_fprm) begin
              unique case (instr.rftype.rm) inside
                [3'b000 : 3'b100]: ;  //legal rounding modes
                3'b101: begin  // Alternative Half-Precision encoded as fmt=10 and rm=101
                  if (~G6LCCfg.XF16ALT || instr.rftype.fmt != 2'b10) illegal_bit = 1'b1;
                  frm_req = 1'b1;  // hyp8: frm_i legality deferred to g6lc_decode_s3
                end
                3'b111: begin
                  // rounding mode from frm csr
                  frm_req = 1'b1;  // hyp8: frm_i legality deferred to g6lc_decode_s3
                end
                default:           illegal_bit = 1'b1;
              endcase
            end
          end else begin
            illegal_bit = 1'b1;
          end
        end

        // ----------------------------------
        // Atomic Operations
        // ----------------------------------
        riscv::OpcodeAmo: begin
          // we are going to use the load unit for AMOs
          cand.fu  = STORE;
          cand.rs1 = instr.atype.rs1;
          cand.rs2 = instr.atype.rs2;
          cand.rd  = instr.atype.rd;
          // TODO(zarubaf): Ordering
          // words
          if (G6LCCfg.RVA && instr.stype.funct3 == 3'h2) begin
            unique case (instr.instr[31:27])
              5'h0: cand.op = g6lc_core_pkg::AMO_ADDW;
              5'h1: cand.op = g6lc_core_pkg::AMO_SWAPW;
              5'h2: begin
                cand.op = g6lc_core_pkg::AMO_LRW;
                if (instr.atype.rs2 != 0) illegal_bit = 1'b1;
              end
              5'h3: cand.op = g6lc_core_pkg::AMO_SCW;
              5'h4: cand.op = g6lc_core_pkg::AMO_XORW;
              // Zacas AMOCAS.W — funct5=00101; rd holds expected (third source)
              5'h5: begin
                if (G6LCCfg.RVZacas) begin
                  cand.op = g6lc_core_pkg::AMO_CASW;
                  imm_select = MUX_RD_RS3;  // result = rd addr → GPR expected
                end else illegal_bit = 1'b1;
              end
              5'h8: cand.op = g6lc_core_pkg::AMO_ORW;
              5'hC: cand.op = g6lc_core_pkg::AMO_ANDW;
              5'h10: cand.op = g6lc_core_pkg::AMO_MINW;
              5'h14: cand.op = g6lc_core_pkg::AMO_MAXW;
              5'h18: cand.op = g6lc_core_pkg::AMO_MINWU;
              5'h1C: cand.op = g6lc_core_pkg::AMO_MAXWU;
              default: illegal_bit = 1'b1;
            endcase
            // double words
          end else if (G6LCCfg.IS_XLEN64 && G6LCCfg.RVA && instr.stype.funct3 == 3'h3) begin
            unique case (instr.instr[31:27])
              5'h0: cand.op = g6lc_core_pkg::AMO_ADDD;
              5'h1: cand.op = g6lc_core_pkg::AMO_SWAPD;
              5'h2: begin
                cand.op = g6lc_core_pkg::AMO_LRD;
                if (instr.atype.rs2 != 0) illegal_bit = 1'b1;
              end
              5'h3: cand.op = g6lc_core_pkg::AMO_SCD;
              5'h4: cand.op = g6lc_core_pkg::AMO_XORD;
              // Zacas AMOCAS.D
              5'h5: begin
                if (G6LCCfg.RVZacas) begin
                  cand.op = g6lc_core_pkg::AMO_CASD;
                  imm_select = MUX_RD_RS3;
                end else illegal_bit = 1'b1;
              end
              5'h8: cand.op = g6lc_core_pkg::AMO_ORD;
              5'hC: cand.op = g6lc_core_pkg::AMO_ANDD;
              5'h10: cand.op = g6lc_core_pkg::AMO_MIND;
              5'h14: cand.op = g6lc_core_pkg::AMO_MAXD;
              5'h18: cand.op = g6lc_core_pkg::AMO_MINDU;
              5'h1C: cand.op = g6lc_core_pkg::AMO_MAXDU;
              default: illegal_bit = 1'b1;
            endcase
          // Zacas AMOCAS.Q — funct3=100, RV64 only; register-pair rd/rs2 must be even
          end else if (G6LCCfg.IS_XLEN64 && G6LCCfg.RVA && G6LCCfg.RVZacas
                       && instr.stype.funct3 == 3'h4) begin
            unique case (instr.instr[31:27])
              5'h5: begin
                cand.op = g6lc_core_pkg::AMO_CASQ;
                imm_select = MUX_RD_RS3;
                // Odd pair base is reserved / illegal.
                // riscv_pkg declares these fields at their instruction bit
                // positions (`atype_t.rd` is [11:7], `rs2` is [24:20]), so the
                // register LSB is bit 7 / bit 20 -- NOT bit 0. Indexing [0] here
                // was out of bounds: Verilator resolves it to X/0 and the check
                // silently never fired, so an odd-pair AMOCAS.Q was accepted
                // instead of being reported illegal. Found by elaborating this
                // decoder under slang for core/formal/g6lc_trap_deliver.sby,
                // which rejects the out-of-bounds index outright.
                if (instr.atype.rd[7] || instr.atype.rs2[20]) illegal_bit = 1'b1;
              end
              default: illegal_bit = 1'b1;
            endcase
          end else begin
            illegal_bit = 1'b1;
          end
          if (G6LCCfg.RVH) begin
            tinst = {
              instr.atype.funct5,
              instr.atype.aq,
              instr.atype.rl,
              instr.atype.rs2,
              5'b0,
              instr.atype.funct3,
              instr.atype.rd,
              instr.atype.opcode
            };
          end
        end

        // --------------------------------
        // Control Flow Instructions
        // --------------------------------
        riscv::OpcodeBranch: begin
          imm_select              = SBIMM;
          cand.fu        = CTRL_FLOW;
          cand.rs1       = instr.stype.rs1;
          cand.rs2       = instr.stype.rs2;

          cf_o = 1'b1;

          case (instr.stype.funct3)
            3'b000: cand.op = g6lc_core_pkg::EQ;
            3'b001: cand.op = g6lc_core_pkg::NE;
            3'b100: cand.op = g6lc_core_pkg::LTS;
            3'b101: cand.op = g6lc_core_pkg::GES;
            3'b110: cand.op = g6lc_core_pkg::LTU;
            3'b111: cand.op = g6lc_core_pkg::GEU;
            default: begin
              cf_o = 1'b0;
              illegal_bit           = 1'b1;
            end
          endcase
        end
        // Jump and link register
        riscv::OpcodeJalr: begin
          cand.fu        = CTRL_FLOW;
          cand.op        = g6lc_core_pkg::JALR;
          cand.rs1       = instr.itype.rs1;
          imm_select              = IIMM;
          cand.rd        = instr.itype.rd;
          cf_o = 1'b1;
          // invalid jump and link register -> reserved for vector encoding
          if (instr.itype.funct3 != 3'b0) illegal_bit = 1'b1;
        end
        // Jump and link
        riscv::OpcodeJal: begin
          cand.fu        = CTRL_FLOW;
          imm_select              = JIMM;
          cand.rd        = instr.utype.rd;
          cf_o = 1'b1;
        end

        riscv::OpcodeAuipc: begin
          cand.fu     = ALU;
          imm_select           = UIMM;
          cand.use_pc = 1'b1;
          cand.rd     = instr.utype.rd;
        end

        riscv::OpcodeLui: begin
          imm_select       = UIMM;
          cand.fu = ALU;
          cand.rd = instr.utype.rd;
        end

        default: illegal_bit = 1'b1;
      endcase
    end
  end

  always_comb begin : sign_extend
    imm_i_type = {{G6LCCfg.XLEN - 12{instruction_i[31]}}, instruction_i[31:20]};
    imm_s_type = {
      {G6LCCfg.XLEN - 12{instruction_i[31]}}, instruction_i[31:25], instruction_i[11:7]
    };
    imm_sb_type = {
      {G6LCCfg.XLEN - 13{instruction_i[31]}},
      instruction_i[31],
      instruction_i[7],
      instruction_i[30:25],
      instruction_i[11:8],
      1'b0
    };
    imm_u_type = {
      {G6LCCfg.XLEN - 32{instruction_i[31]}}, instruction_i[31:12], 12'b0
    };  // JAL, AUIPC, sign extended to 64 bit
    //  if zcmt then xlen jump address assign to immediate
    if (G6LCCfg.RVZCMT && is_zcmt_i) begin
      imm_uj_type = {{G6LCCfg.XLEN - 32{jump_address_i[31]}}, jump_address_i[31:0]};
    end else begin
      imm_uj_type = {
        {G6LCCfg.XLEN - 20{instruction_i[31]}},
        instruction_i[19:12],
        instruction_i[20],
        instruction_i[30:21],
        1'b0
      };
    end

    // NOIMM, IIMM, SIMM, SBIMM, UIMM, JIMM, RS3
    // select immediate
    case (imm_select)
      IIMM: begin
        cand.result  = imm_i_type;
        cand.use_imm = 1'b1;
      end
      SIMM: begin
        cand.result  = imm_s_type;
        cand.use_imm = 1'b1;
      end
      SBIMM: begin
        cand.result  = imm_sb_type;
        cand.use_imm = 1'b1;
      end
      UIMM: begin
        cand.result  = imm_u_type;
        cand.use_imm = 1'b1;
      end
      JIMM: begin
        cand.result  = imm_uj_type;
        cand.use_imm = 1'b1;
      end
      RS3: begin
        // result holds address of fp operand rs3
        cand.result  = {{G6LCCfg.XLEN - 5{1'b0}}, instr.r4type.rs3};
        cand.use_imm = 1'b0;
      end
      MUX_RD_RS3: begin
        // result holds address of operand rs3 which is in rd field
        cand.result  = {{G6LCCfg.XLEN - 5{1'b0}}, instr.rtype.rd};
        cand.use_imm = 1'b0;
      end
      default: begin
        cand.result  = {G6LCCfg.XLEN{1'b0}};
        cand.use_imm = 1'b0;
      end
    endcase

  end

endmodule
