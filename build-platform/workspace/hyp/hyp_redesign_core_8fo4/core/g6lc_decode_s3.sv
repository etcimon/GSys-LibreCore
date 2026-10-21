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

// g6lc_decode_s3 (D3): privilege/CSR-state legality + final scoreboard-entry
// and exception assembly. Contains every conditional the original decoder
// evaluated against live architectural state (priv_lvl/v/fs/vfs/frm/vs/tvm/
// tw/vtw/tsr/hu, CBIE/CBCFE/CBZE, debug_mode, irq_ctrl) plus the CVXIF
// offload / accelerator overrides and the interrupt/debug injection tail --
// all verbatim relocations.

module g6lc_decode_s3
  import g6lc_core_pkg::*;
#(
    parameter config_pkg::g6lc_cfg_t G6LCCfg = config_pkg::g6lc_cfg_empty,
    parameter type exception_t = logic,
    parameter type irq_ctrl_t = logic,
    parameter type scoreboard_entry_t = logic,
    parameter type interrupts_t = logic,
    parameter interrupts_t INTERRUPTS = '0
) (
    input  scoreboard_entry_t               dec_i,    // D2 candidate
    input  logic [31:0]                     instr_i,  // expanded instruction
    input  logic [31:0]                     tinst_i,  // D2 transformed instr
    input  logic [15:0]                     compressed_instr_i,
    input  logic                            is_compressed_i,
    input  logic                            is_illegal_i,
    input  exception_t                      ex_i,
    input  logic [G6LCCfg.VLEN-1:0]         pc_i,
    input  logic                            ecall_i,
    input  logic                            ebreak_i,
    input  logic                            frm_req_i,
    input  logic                            check_fprm_i,
    input  logic                            fp_hit_i,
    input  logic                            illegal_i,  // bit-decode illegal
    input  logic                            cf_i,       // control-flow class
    // ----- privilege / CSR / interrupt / debug state (verbatim decoder set) ---
    input  logic                            debug_req_i,
    input  riscv::priv_lvl_t                priv_lvl_i,
    input  logic                            v_i,
    input  logic                            debug_mode_i,
    input  riscv::xs_t                      fs_i,
    input  riscv::xs_t                      vfs_i,
    input  logic [2:0]                      frm_i,
    input  riscv::xs_t                      vs_i,
    input  logic                            tvm_i,
    input  logic                            tw_i,
    input  logic                            vtw_i,
    input  logic                            tsr_i,
    input  logic                            hu_i,
    input  riscv::cbie_t                    mcbie_i,
    input  riscv::cbie_t                    scbie_i,
    input  riscv::cbie_t                    hcbie_i,
    input  logic                            mcbcfe_i,
    input  logic                            scbcfe_i,
    input  logic                            hcbcfe_i,
    input  logic                            mcbze_i,
    input  logic                            scbze_i,
    input  logic                            hcbze_i,
    input  logic [1:0]                      irq_i,
    input  irq_ctrl_t                       irq_ctrl_i,
    input  logic                            debug_from_trigger_i,
    // ----- outputs -----
    output scoreboard_entry_t               instruction_o,
    output logic [31:0]                     orig_instr_o,
    output logic                            is_control_flow_instr_o
);
  logic illegal;         // illegal_i | legality violations (accel may override)
  logic virt;            // virtual-instruction violations
  logic illegal_fin;     // illegal after the accelerator override
  logic cf_fin;
  g6lc_core_pkg::fu_op opfix;// legality-side op corrections (ADD squash, CBO demote)
  scoreboard_entry_t w;  // assembled candidate
  riscv::instruction_t instr;
  assign instr = riscv::instruction_t'(instr_i);

  // ---------------------------------------
  // Accelerator instructions' first-pass decoder
  // ---------------------------------------
  logic is_accel;
  scoreboard_entry_t acc_instruction;
  logic acc_illegal_instr;
  logic acc_is_control_flow_instr;

  if (G6LCCfg.EnableAccelerator) begin : gen_accel_decoder
    // This module is responsible for a light-weight decoding of accelerator instructions,
    // identifying them, but also whether they read/write scalar registers.
    // Accelerators are supposed to define this module.
    g6lc_accel_first_pass_decoder #(
        .G6LCCfg(G6LCCfg),
        .scoreboard_entry_t(scoreboard_entry_t)
    ) i_accel_decoder (
        .instruction_i(instr_i),
        .fs_i(fs_i),
        .vs_i(vs_i),
        .is_accel_o(is_accel),
        .instruction_o(acc_instruction),
        .illegal_instr_o(acc_illegal_instr),
        .is_control_flow_instr_o(acc_is_control_flow_instr)
    );
  end : gen_accel_decoder
  else begin
    assign is_accel                  = 1'b0;
    assign acc_instruction           = '0;
    assign acc_illegal_instr         = 1'b1;  // this should never propagate
    assign acc_is_control_flow_instr = 1'b0;
  end


  // ---------------------------------------------------------------------
  // hyp8 D3 legality: every conditional below is a verbatim relocation of a
  // check the original decoder evaluated inside its single always_comb that
  // reads architectural / CSR state (priv_lvl, v, fs/vfs, tvm/tw/vtw/tsr,
  // hu, cbie/cbcfe/cbze, debug_mode) rather than instruction bits.  All of
  // it runs gated by ~ex_i.valid exactly like the original opcode case.
  // Arm identity comes from the op D2 decoded (SRET/MRET/DRET/WFI and the
  // sfence/hfence/CBO ops are set by exactly one arm each).
  // ---------------------------------------------------------------------
  always_comb begin : legality
    // hyp8: the emit's serial if-chain is rewritten as independent compare
    // nets. Set-only arms (the large majority) accumulate by OR. The three
    // arms that can REPLACE illegal/virt (SFENCE.VMA priv write, HFENCE.VVMA,
    // HFENCE.GVMA -- each writes 0 or 1) are applied as an ordered override
    // chain; they are op-disjoint so at most one fires. The only earlier
    // arm that can co-fire with them is the rs1/rd-nonzero check (same
    // System/funct3==000 group, no op key), so pre/post-set partitioning
    // reproduces the emit's last-writer order exactly.
    logic sys_f000, sys_f100;
    logic ill_rs1rd, v_rs1rd;
    logic c_sret, c_mret, c_dret, c_wfi, c_sf, c_hvv, c_hgv, c_ci, c_cf, c_cz;
    logic ill_sret_u, v_sret_u, ill_sret_tsr, v_sret_tsr;
    logic ill_mret, ill_dret;
    logic ill_wfi_tw, v_wfi_vtw, ill_wfi_u, v_wfi_u;
    logic ill_sf_tvm, v_sf_tvm;
    logic ill_hgv_tvm;
    logic ill_hlv, v_hlv;
    logic ill_ci, v_ci, fix_ci;
    logic ill_cf, v_cf;
    logic ill_cz, v_cz;
    logic ill_fp, ill_frm;
    logic ill_ci_c, v_ci_c, f_ci_c;
    logic ill_cf_c, v_cf_c, ill_cz_c, v_cz_c;
    logic priv_ms_rd0;
    logic fix_add;
    logic illA, virA, illB, virB, illC, virC, illD, virD;

    sys_f000 = (instr.rtype.opcode == riscv::OpcodeSystem) &&
               (instr.itype.funct3 == 3'b000);
    sys_f100 = G6LCCfg.RVH && (instr.rtype.opcode == riscv::OpcodeSystem) &&
               (instr.itype.funct3 == 3'b100);
    c_sret = sys_f000 && (dec_i.op == g6lc_core_pkg::SRET);
    c_mret = sys_f000 && (dec_i.op == g6lc_core_pkg::MRET);
    c_dret = sys_f000 && (dec_i.op == g6lc_core_pkg::DRET);
    c_wfi  = sys_f000 && (dec_i.op == g6lc_core_pkg::WFI);
    c_sf   = sys_f000 && (dec_i.op == g6lc_core_pkg::SFENCE_VMA);
    c_hvv  = sys_f000 && (dec_i.op == g6lc_core_pkg::HFENCE_VVMA);
    c_hgv  = sys_f000 && (dec_i.op == g6lc_core_pkg::HFENCE_GVMA);
    c_ci   = G6LCCfg.RVZiCbom && (dec_i.op == g6lc_core_pkg::CBO_INVAL);
    c_cz   = (dec_i.op == g6lc_core_pkg::CBO_ZERO);
    priv_ms_rd0 = (priv_lvl_i inside {riscv::PRIV_LVL_M, riscv::PRIV_LVL_S}) &&
                  (instr.itype.rd == '0);

    // rs1/rd-nonzero encoding under System/funct3=000 (can co-fire with the
    // SFENCE/HFENCE arms, hence it is in the pre-set group)
    ill_rs1rd = sys_f000 && (instr.itype.rs1 != '0 || instr.itype.rd != '0) &&
                !(G6LCCfg.RVH && v_i);
    v_rs1rd   = sys_f000 && (instr.itype.rs1 != '0 || instr.itype.rd != '0) &&
                G6LCCfg.RVH && v_i;
    // SRET
    ill_sret_u   = c_sret && G6LCCfg.RVU && (priv_lvl_i == riscv::PRIV_LVL_U) &&
                   !(G6LCCfg.RVH && v_i);
    v_sret_u     = c_sret && G6LCCfg.RVU && (priv_lvl_i == riscv::PRIV_LVL_U) &&
                   G6LCCfg.RVH && v_i;
    ill_sret_tsr = c_sret && (priv_lvl_i == riscv::PRIV_LVL_S) && tsr_i &&
                   !(G6LCCfg.RVH && v_i);
    v_sret_tsr   = c_sret && (priv_lvl_i == riscv::PRIV_LVL_S) && tsr_i &&
                   G6LCCfg.RVH && v_i;
    // MRET / DRET
    ill_mret = c_mret && ((G6LCCfg.RVS && priv_lvl_i == riscv::PRIV_LVL_S) ||
                          (G6LCCfg.RVU && priv_lvl_i == riscv::PRIV_LVL_U));
    ill_dret = c_dret && G6LCCfg.DebugEn && !debug_mode_i;
    // WFI (+Zawrs WRS.NTO/STO): three sub-arms all squash op to ADD
    ill_wfi_tw = c_wfi && G6LCCfg.RVS && (priv_lvl_i == riscv::PRIV_LVL_S) && tw_i;
    v_wfi_vtw  = c_wfi && G6LCCfg.RVH && (priv_lvl_i == riscv::PRIV_LVL_S) &&
                 v_i && vtw_i && !tw_i;
    ill_wfi_u  = c_wfi && G6LCCfg.RVU && (priv_lvl_i == riscv::PRIV_LVL_U) &&
                 !(G6LCCfg.RVH && v_i);
    v_wfi_u    = c_wfi && G6LCCfg.RVU && (priv_lvl_i == riscv::PRIV_LVL_U) &&
                 G6LCCfg.RVH && v_i;
    // SFENCE.VMA tvm intercept (the priv write itself is the override below)
    ill_sf_tvm = c_sf && G6LCCfg.RVS && (priv_lvl_i == riscv::PRIV_LVL_S) &&
                 tvm_i && !(G6LCCfg.RVH && v_i);
    v_sf_tvm   = c_sf && G6LCCfg.RVS && (priv_lvl_i == riscv::PRIV_LVL_S) &&
                 tvm_i && G6LCCfg.RVH && v_i;
    // HFENCE.GVMA tvm intercept
    ill_hgv_tvm = c_hgv && (priv_lvl_i == riscv::PRIV_LVL_S) && !v_i && tvm_i;
    // HLV/HSV (funct3==100 group -- never co-fires with the funct3==000 arms)
    v_hlv   = sys_f100 && v_i;
    ill_hlv = sys_f100 && !v_i && !hu_i && (priv_lvl_i == riscv::PRIV_LVL_U);
    // CBO_INVAL: illegal -> virt -> demote-to-FLUSH (else-if order kept by
    // masking each later term with the earlier conditions' negations)
    ill_ci_c = (priv_lvl_i != riscv::PRIV_LVL_M && mcbie_i == riscv::CBIE_ILLEGAL) ||
               (G6LCCfg.RVU && priv_lvl_i == riscv::PRIV_LVL_U &&
                scbie_i == riscv::CBIE_ILLEGAL);
    v_ci_c   = (priv_lvl_i == riscv::PRIV_LVL_HS && hcbie_i == riscv::CBIE_ILLEGAL) ||
               (priv_lvl_i == riscv::PRIV_LVL_U && hu_i);
    f_ci_c   = (priv_lvl_i != riscv::PRIV_LVL_M && mcbie_i == riscv::CBIE_FLUSH) ||
               (priv_lvl_i == riscv::PRIV_LVL_U && scbie_i == riscv::CBIE_FLUSH) ||
               (priv_lvl_i == riscv::PRIV_LVL_HS && hcbie_i == riscv::CBIE_FLUSH) ||
               (priv_lvl_i == riscv::PRIV_LVL_U && hu_i &&
                (hcbie_i == riscv::CBIE_FLUSH || scbie_i == riscv::CBIE_FLUSH));
    ill_ci = c_ci && ill_ci_c;
    v_ci   = c_ci && !ill_ci_c && v_ci_c;
    fix_ci = c_ci && !ill_ci_c && !v_ci_c && f_ci_c;
    // CBO_CLEAN/FLUSH legality -- also covers an INVAL demoted this cycle
    // (the emit reads the post-fix opfix, so the demote makes this arm fire).
    c_cf = G6LCCfg.RVZiCbom &&
           ((dec_i.op inside {g6lc_core_pkg::CBO_CLEAN,
                              g6lc_core_pkg::CBO_FLUSH}) || fix_ci);
    ill_cf_c = (priv_lvl_i != riscv::PRIV_LVL_M && !mcbcfe_i) ||
               (priv_lvl_i == riscv::PRIV_LVL_U && !scbcfe_i);
    v_cf_c   = (priv_lvl_i == riscv::PRIV_LVL_HS && !hcbcfe_i) ||
               (priv_lvl_i == riscv::PRIV_LVL_U && hu_i &&
                !(hcbcfe_i && scbcfe_i));
    ill_cf = c_cf && ill_cf_c;
    v_cf   = c_cf && !ill_cf_c && v_cf_c;
    // CBO.ZERO
    ill_cz_c = (priv_lvl_i != riscv::PRIV_LVL_M && !mcbze_i) ||
               (priv_lvl_i == riscv::PRIV_LVL_U && !scbze_i);
    v_cz_c   = (priv_lvl_i == riscv::PRIV_LVL_HS && !hcbze_i) ||
               (priv_lvl_i == riscv::PRIV_LVL_U && hu_i &&
                !(hcbze_i && scbze_i));
    ill_cz = c_cz && ill_cz_c;
    v_cz   = c_cz && !ill_cz_c && v_cz_c;
    // fs/vfs gate on FP ops decoded in D2
    ill_fp = fp_hit_i &&
             !(fs_i != riscv::Off &&
               ((G6LCCfg.RVH && (!v_i || vfs_i != riscv::Off)) ||
                !G6LCCfg.RVH));
    // frm legality (legal modes are 3'b000..3'b100)
    ill_frm = frm_req_i && (frm_i > 3'd4);

    // --- pre-clearing-arm set accumulation (emit order preserved) ---
    illA = illegal_i | ill_rs1rd | ill_sret_u | ill_sret_tsr | ill_mret |
           ill_dret | ill_wfi_tw | ill_wfi_u;
    virA = v_rs1rd | v_sret_u | v_sret_tsr | v_wfi_vtw | v_wfi_u;
    // --- SFENCE.VMA: priv write replaces, then tvm arm sets ---
    illB = (c_sf && !(G6LCCfg.RVH && v_i))
           ? ~(G6LCCfg.RVS && priv_ms_rd0) : illA;
    virB = (c_sf && G6LCCfg.RVH && v_i)
           ? (priv_lvl_i != riscv::PRIV_LVL_S) : virA;
    illB = illB | ill_sf_tvm;
    virB = virB | v_sf_tvm;
    // --- HFENCE.VVMA ---
    illC = (c_hvv && !v_i) ? !priv_ms_rd0 : illB;
    virC = (c_hvv && v_i) ? 1'b1 : virB;
    // --- HFENCE.GVMA + tvm ---
    illD = (c_hgv && !v_i) ? !priv_ms_rd0 : illC;
    virD = (c_hgv && v_i) ? 1'b1 : virC;
    illD = illD | ill_hgv_tvm;
    // --- post arms: HLV/HSV, CBO, fs, frm (set-only, last in the emit) ---
    illegal = ~ex_i.valid ? (illD | ill_hlv | ill_ci | ill_cf | ill_cz |
                             ill_fp | ill_frm)
                          : illegal_i;
    virt    = ~ex_i.valid & (virD | v_hlv | v_ci | v_cf | v_cz);
    fix_add = ill_sret_u | v_sret_u | ill_sret_tsr | v_sret_tsr |
              ill_wfi_tw | v_wfi_vtw | ill_wfi_u | v_wfi_u;
    opfix   = ex_i.valid ? dec_i.op
            : fix_ci ? g6lc_core_pkg::CBO_FLUSH
            : (fix_add ? g6lc_core_pkg::ADD : dec_i.op);
  end

  // ---------------------------------------------------------------------
  // assembly: op corrections + CVXIF offload + accelerator override, in the
  // original's order (cvxif sees pre-accelerator illegal; accel wins last).
  // ---------------------------------------------------------------------
  always_comb begin : assemble
    w       = dec_i;
    w.op    = opfix;
    cf_fin  = cf_i;
    illegal_fin = illegal;

    if (G6LCCfg.CvxifEn) begin
      if (~ex_i.valid && (is_illegal_i || illegal)) begin
        w.fu = CVXIF;
        w.rs1 = instr.r4type.rs1;
        w.rs2 = instr.r4type.rs2;
        w.rd = instr.r4type.rd;
        w.op = g6lc_core_pkg::OFFLOAD;
        // hyp8: original drove the immediate-select RS3/MUX_RD_RS3 here; the
        // final result is computed directly (same values that select produces).
        w.result              = (instr.rtype.opcode == riscv::OpcodeMadd ||
                                 instr.rtype.opcode == riscv::OpcodeMsub ||
                                 instr.rtype.opcode == riscv::OpcodeNmadd ||
                                 instr.rtype.opcode == riscv::OpcodeNmsub)
                                ? {{G6LCCfg.XLEN - 5{1'b0}}, instr.r4type.rs3}
                                : {{G6LCCfg.XLEN - 5{1'b0}}, instr.rtype.rd};
        w.use_imm             = 1'b0;
      end
    end

    // Accelerator instructions.
    // These can overwrite the previous decoding entirely.
    if (G6LCCfg.EnableAccelerator) begin // only generate decoder if accelerators are enabled (static)
      if (is_accel) begin
        w.fu        = acc_instruction.fu;
        w.vfp       = acc_instruction.vfp;
        w.rs1       = acc_instruction.rs1;
        w.rs2       = acc_instruction.rs2;
        w.rd        = acc_instruction.rd;
        w.op        = acc_instruction.op;
        illegal_fin       = acc_illegal_instr;
        cf_fin            = acc_is_control_flow_instr;
      end
    end
  end

  // ---------------------
  // Exception handling
  // ---------------------
  logic [G6LCCfg.XLEN-1:0] interrupt_cause;

  // this instruction has already executed if the exception is valid

  // hyp8 r4: field-group split -- the exception record (ex.valid/cause/
  // tval/tinst, interrupt and debug overrides, original priority order)
  // is assembled as ex_fin in its own block; the output record group
  // (instruction_o fields + orig_instr_o) is a second, shallow block.
  exception_t ex_fin;

  always_comb begin : ex_assemble
    interrupt_cause = '0;
    ex_fin = ex_i;
    // look if we didn't already get an exception in any previous
    // stage - we should not overwrite it as we retain order regarding the exception
    if (~ex_i.valid) begin
      if (G6LCCfg.TvalEn)
        ex_fin.tval  = (is_compressed_i) ? {{G6LCCfg.XLEN-16{1'b0}}, compressed_instr_i} : {{G6LCCfg.XLEN-32{1'b0}}, instr_i};
      else ex_fin.tval = '0;
      if (G6LCCfg.RVH) ex_fin.tinst = tinst_i;
      else ex_fin.tinst = '0;
      // instructions which will throw an exception are marked as valid
      // e.g.: they can be committed anytime and do not need to wait for any functional unit
      // check here if we decoded an invalid instruction or if the compressed decoder already decoded
      // a invalid instruction
      if (illegal_fin || is_illegal_i) begin
        if (!G6LCCfg.CvxifEn) ex_fin.valid = 1'b1;
        // we decoded an illegal exception here
        ex_fin.cause = riscv::ILLEGAL_INSTR;
      end else if (G6LCCfg.RVH && virt) begin
        ex_fin.valid = 1'b1;
        // we decoded an virtual illegal exception here
        ex_fin.cause = riscv::VIRTUAL_INSTRUCTION;
        // we got an ecall_i, set the correct cause depending on the current privilege level
      end else if (ecall_i) begin
        // this exception is valid
        ex_fin.valid = 1'b1;
        // depending on the privilege mode, set the appropriate cause
        if (priv_lvl_i == riscv::PRIV_LVL_S && G6LCCfg.RVS) begin
          ex_fin.cause = (G6LCCfg.RVH && v_i) ? riscv::ENV_CALL_VSMODE : riscv::ENV_CALL_SMODE;
        end else if (priv_lvl_i == riscv::PRIV_LVL_U && G6LCCfg.RVU) begin
          ex_fin.cause = riscv::ENV_CALL_UMODE;
        end else if (priv_lvl_i == riscv::PRIV_LVL_M) begin
          ex_fin.cause = riscv::ENV_CALL_MMODE;
        end
        if (G6LCCfg.TvalEn) ex_fin.tval = '0;
      end else if (ebreak_i) begin
        // this exception is valid
        ex_fin.valid = 1'b1;
        // set breakpoint cause
        ex_fin.cause = riscv::BREAKPOINT;
        // set gva bit
        if (G6LCCfg.RVH) ex_fin.gva = v_i;
        else ex_fin.gva = 1'b0;
        if (G6LCCfg.TvalEn) ex_fin.tval = pc_i;
      end
    end
    // -----------------
    // Interrupt Control
    // -----------------
    // we decode an interrupt the same as an exception, hence it will be taken if the instruction did not
    // throw any previous exception.
    // we have three interrupt sources: external interrupts, software interrupts, timer interrupts (order of precedence)
    // for two privilege levels: Supervisor and Machine Mode
    // Virtual Supervisor Timer Interrupt
    if (G6LCCfg.RVH) begin
      if (irq_ctrl_i.mie[riscv::IRQ_VS_TIMER] && irq_ctrl_i.mip[riscv::IRQ_VS_TIMER]) begin
        interrupt_cause = INTERRUPTS.VS_TIMER;
      end
      // Virtual Supervisor Software Interrupt
      if (irq_ctrl_i.mie[riscv::IRQ_VS_SOFT] && irq_ctrl_i.mip[riscv::IRQ_VS_SOFT]) begin
        interrupt_cause = INTERRUPTS.VS_SW;
      end
      // Virtual Supervisor External Interrupt
      if (irq_ctrl_i.mie[riscv::IRQ_VS_EXT] && (irq_ctrl_i.mip[riscv::IRQ_VS_EXT])) begin
        interrupt_cause = INTERRUPTS.VS_EXT;
      end
      // Hypervisor Guest External Interrupts
      if (irq_ctrl_i.mie[riscv::IRQ_HS_EXT] && irq_ctrl_i.mip[riscv::IRQ_HS_EXT]) begin
        interrupt_cause = INTERRUPTS.HS_EXT;
      end
    end
    // Sscofpmf LCOFI has the lowest default priority among the standard major
    // interrupts, so it is evaluated first (later assignments win).
    if (G6LCCfg.SscofpmfEn) begin
      if (irq_ctrl_i.mie[riscv::IRQ_LCOF] && irq_ctrl_i.mip[riscv::IRQ_LCOF]) begin
        interrupt_cause = INTERRUPTS.LCOF;
      end
    end
    if (G6LCCfg.RVS) begin
      // Supervisor Timer Interrupt
      if (irq_ctrl_i.mie[riscv::IRQ_S_TIMER] && irq_ctrl_i.mip[riscv::IRQ_S_TIMER]) begin
        interrupt_cause = INTERRUPTS.S_TIMER;
      end
      // Supervisor Software Interrupt
      if (irq_ctrl_i.mie[riscv::IRQ_S_SOFT] && irq_ctrl_i.mip[riscv::IRQ_S_SOFT]) begin
        interrupt_cause = INTERRUPTS.S_SW;
      end
      // Supervisor External Interrupt
      // The logical-OR of the software-writable bit and the signal from the external interrupt controller is
      // used to generate external interrupts to the supervisor
      if (irq_ctrl_i.mie[riscv::IRQ_S_EXT] && (irq_ctrl_i.mip[riscv::IRQ_S_EXT] | irq_i[g6lc_core_pkg::SupervisorIrq])) begin
        interrupt_cause = INTERRUPTS.S_EXT;
      end
    end
    // Machine Timer Interrupt
    if (irq_ctrl_i.mip[riscv::IRQ_M_TIMER] && irq_ctrl_i.mie[riscv::IRQ_M_TIMER]) begin
      interrupt_cause = INTERRUPTS.M_TIMER;
    end
    if (G6LCCfg.SoftwareInterruptEn) begin
      // Machine Mode Software Interrupt
      if (irq_ctrl_i.mip[riscv::IRQ_M_SOFT] && irq_ctrl_i.mie[riscv::IRQ_M_SOFT]) begin
        interrupt_cause = INTERRUPTS.M_SW;
      end
    end
    // Machine Mode External Interrupt
    if (irq_ctrl_i.mip[riscv::IRQ_M_EXT] && irq_ctrl_i.mie[riscv::IRQ_M_EXT]) begin
      interrupt_cause = INTERRUPTS.M_EXT;
    end

    if (interrupt_cause[G6LCCfg.XLEN-1] && irq_ctrl_i.global_enable) begin
      // However, if bit i in mideleg is set, interrupts are considered to be globally enabled if the hart’s current privilege
      // mode equals the delegated privilege mode (S or U) and that mode’s interrupt enable bit
      // (SIE or UIE in mstatus) is set, or if the current privilege mode is less than the delegated privilege mode.
      if (irq_ctrl_i.mideleg[interrupt_cause[$clog2(G6LCCfg.XLEN)-1:0]]) begin
        if (G6LCCfg.RVH) begin : hyp_int_gen
          if (v_i && irq_ctrl_i.hideleg[interrupt_cause[$clog2(G6LCCfg.XLEN)-1:0]]) begin
            if ((irq_ctrl_i.sie && priv_lvl_i == riscv::PRIV_LVL_S) || priv_lvl_i == riscv::PRIV_LVL_U) begin
              ex_fin.valid = 1'b1;
              ex_fin.cause = interrupt_cause;
            end
          end else if (v_i && ~irq_ctrl_i.hideleg[interrupt_cause[$clog2(G6LCCfg.XLEN)-1:0]]) begin
            ex_fin.valid = 1'b1;
            ex_fin.cause = interrupt_cause;
          end else if (!v_i && ((irq_ctrl_i.sie && priv_lvl_i == riscv::PRIV_LVL_S) || priv_lvl_i == riscv::PRIV_LVL_U) && ~irq_ctrl_i.hideleg[interrupt_cause[$clog2(
                  G6LCCfg.XLEN
              )-1:0]]) begin
            ex_fin.valid = 1'b1;
            ex_fin.cause = interrupt_cause;
          end
        end else begin
          if ((G6LCCfg.RVS && irq_ctrl_i.sie && priv_lvl_i == riscv::PRIV_LVL_S) || (G6LCCfg.RVU && priv_lvl_i == riscv::PRIV_LVL_U)) begin
            ex_fin.valid = 1'b1;
            ex_fin.cause = interrupt_cause;
          end
        end
      end else begin
        ex_fin.valid = 1'b1;
        ex_fin.cause = interrupt_cause;
      end
    end

    // a debug request has precendece over everything else
    if ((G6LCCfg.DebugEn && debug_req_i && !debug_mode_i) || (G6LCCfg.SDTRIG && G6LCCfg.Mcontrol6 && G6LCCfg.DebugEn && !debug_mode_i && debug_from_trigger_i)) begin
      ex_fin.valid = 1'b1;
      ex_fin.cause = riscv::DEBUG_REQUEST;
    end
  end

  // Output record group: w + assembled exception + orig-instr shadow.
  always_comb begin : out_assemble
    instruction_o    = w;
    instruction_o.ex = ex_fin;
    orig_instr_o = '0;
    // if we didn't already get an exception save the instruction here as we may need it
    // in the commit stage if we got a access exception to one of the CSR registers
    if (~ex_i.valid && (G6LCCfg.CvxifEn || G6LCCfg.RVF || G6LCCfg.ZKN))
      orig_instr_o = (is_compressed_i) ? {16'b0, compressed_instr_i} : instr_i;
    // hyp8: ex valid (was a continuous assign in the single-comb
    // original; moved inside this block to avoid a multi-driver field)
    instruction_o.valid = ex_fin.valid;
  end

  assign is_control_flow_instr_o = cf_fin;
endmodule
