// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// Bounded formal: DECODE NEVER WITHHOLDS AN ILLEGAL-INSTRUCTION EXCEPTION.
// Proven against the LIVE `decoder` (`core/decoder.sv`), not a policy model --
// the defect this pins lived in the real module and a self-contained model would
// have reproduced the intent rather than the code.
//
// The obligation, stated without reference to any address, register, opcode or
// OpenSBI symbol:
//
//   For every instruction that decode classifies as illegal -- whether from the
//   32-bit decoder itself (`illegal_instr`) or handed down by the compressed
//   decoder (`is_illegal_i`) -- and for which no earlier-stage exception is
//   already pending (`ex_i.valid`), the scoreboard entry leaving decode must
//   carry `ex.valid` with cause ILLEGAL_INSTR.
//
// Why this is the right rung. RISC-V requires a PRECISE trap for an illegal
// instruction; every self-armed CSR probe depends on it
// (`include/sbi/sbi_csr_detect.h:17` arms mtvec and executes a maybe-illegal
// read; `lib/sbi/sbi_expected_trap.S:23` advances mepc by a fixed +4 and mrets;
// `lib/sbi/sbi_hart.c:771` repeats that dozens of times on the coldboot path).
// If decode can *silently decline* to raise the exception, the probe neither
// traps nor retires and the machine wedges -- and no amount of firmware soaking
// localises it, because the firmware is a correct witness of a broken core.
// This is a single-module combinational obligation, so L2 is the earliest rung
// that can express it: push it left rather than re-running a soak.
//
// The recorded negative: with CvxifEn set, `core/decoder.sv:1976` reads
//     if (!CVA6Cfg.CvxifEn) instruction_o.ex.valid = 1'b1;
// so the exception is deliberately withheld to let a coprocessor claim the
// encoding, and is re-raised only from a CVXIF *rejection*
// (`core/cvxif_fu.sv:69`). But every gate on that path keys off issue port 0
// (`core/issue_read_operands.sv:288`), so on a multi-issue core an illegal
// instruction on any other port is never re-raised. `check_cfg` now rejects
// `CvxifEn && NrIssuePorts > 1` outright; this proof is what keeps that honest.
//
// TWO TASKS, because a proof that cannot fail proves nothing (the same
// positive/negative discipline the DI battery applies to its oracle):
//   ok  : CvxifEn = 0 -- the shipped multi-issue setting. MUST PASS.
//   bug : CvxifEn = 1 -- MUST FAIL (`expect fail`), which is the machine-checked
//         statement that the withheld `ex.valid` is real and that the check_cfg
//         guard is load-bearing rather than decorative. If `bug` ever starts
//         passing, the CVXIF offload path has changed and the guard should be
//         revisited -- do not simply delete the task.
//
// Run: sby -f core/formal/g6lc_trap_deliver.sby
//      cva6-build verify --formal

`include "g6lc_core_types.svh"

module g6lc_trap_deliver_props #(
    parameter int unsigned NI = 2
) (
    input logic clk_i
);

`ifdef FORMAL
  import ariane_pkg::*;

  localparam int unsigned XLEN  = 64;
  localparam int unsigned VLEN  = 64;
  localparam int unsigned GPLEN = 64;

`ifdef G6LC_TRAP_CVXIF
  localparam bit CVXIF_EN = 1'b1;
`else
  localparam bit CVXIF_EN = 1'b0;
`endif

  // Minimal legal cfg for the decoder. Kept deliberately close to the shipped
  // multi-issue envelope (RVC/RVS/RVU/RVH on, 2..8 issue) so the proof speaks
  // about a configuration the project actually builds, not a toy.
  function automatic config_pkg::cva6_cfg_t mk_cfg();
    config_pkg::cva6_cfg_t c;
    c                = config_pkg::cva6_cfg_empty;
    c.XLEN           = XLEN;
    c.VLEN           = VLEN;
    c.GPLEN          = GPLEN;
    c.RVC            = 1'b1;
    c.RVS            = 1'b1;
    c.RVU            = 1'b1;
    c.RVH            = 1'b0;
    c.RVF            = 1'b0;
    c.RVD            = 1'b0;
    c.RVV            = 1'b0;
    c.RVA            = 1'b1;
    c.RVZiCond       = 1'b0;
    c.CvxifEn        = CVXIF_EN;
    c.EnableAccelerator = 1'b0;
    c.TvalEn         = 1'b1;
    c.DebugEn        = 1'b0;
    c.NrHarts        = 1;
    c.NrCores        = 1;
    c.NrIssuePorts   = NI;
    c.SuperscalarEn  = (NI > 1);
    c.NrCommitPorts  = (NI > 1) ? NI : 1;
    c.SoftwareInterruptEn = 1'b1;
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t Cfg = mk_cfg();

  // Types come from the shared macro header, NOT hand-copied: a props file whose
  // struct layout has silently drifted from core/cva6.sv still elaborates and
  // still "passes" while checking a different machine. See the header of
  // core/include/g6lc_core_types.svh.
  typedef `G6LC_BRANCHPREDICT_SBE_T(Cfg) branchpredict_sbe_t;
  typedef `G6LC_EXCEPTION_T(Cfg) exception_t;
  typedef `G6LC_IRQ_CTRL_T(Cfg) irq_ctrl_t;
  typedef `G6LC_SCOREBOARD_ENTRY_T(Cfg) scoreboard_entry_t;
  typedef `G6LC_INTERRUPTS_T(Cfg) interrupts_t;

  localparam interrupts_t INTERRUPTS = '{
      S_SW: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_S_SOFT),
      VS_SW: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_VS_SOFT),
      M_SW: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_M_SOFT),
      S_TIMER: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_S_TIMER),
      VS_TIMER: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_VS_TIMER),
      M_TIMER: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_M_TIMER),
      S_EXT: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_S_EXT),
      VS_EXT: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_VS_EXT),
      M_EXT: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_M_EXT),
      HS_EXT: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_HS_EXT),
      LCOF: (XLEN'(1) << (XLEN - 1)) | XLEN'(riscv::IRQ_LCOF)
  };

  // ---- free environment ----------------------------------------------------
  // Every decoder input is unconstrained: the claim must hold for ALL bytes, all
  // privilege levels and all CSR-visible state, not for a curated stimulus set.
  logic                  debug_req_i;
  logic [   VLEN-1:0]    pc_i;
  logic                  is_compressed_i;
  logic [       15:0]    compressed_instr_i;
  logic                  is_illegal_i;
  logic [       31:0]    instruction_i;
  logic                  is_macro_instr_i;
  logic                  is_last_macro_instr_i;
  logic                  is_double_rd_macro_instr_i;
  logic                  is_zcmt_i;
  logic [   XLEN-1:0]    jump_address_i;
  branchpredict_sbe_t    branch_predict_i;
  exception_t            ex_i;
  logic [        1:0]    irq_i;
  irq_ctrl_t             irq_ctrl_i;
  riscv::priv_lvl_t      priv_lvl_i;
  logic                  v_i;
  logic                  debug_mode_i;
  riscv::xs_t            fs_i;
  riscv::xs_t            vfs_i;
  logic [        2:0]    frm_i;
  riscv::xs_t            vs_i;
  logic                  tvm_i;
  logic                  tw_i;
  logic                  vtw_i;
  logic                  tsr_i;
  logic                  hu_i;
  riscv::cbie_t          mcbie_i;
  riscv::cbie_t          scbie_i;
  riscv::cbie_t          hcbie_i;
  logic                  mcbcfe_i;
  logic                  scbcfe_i;
  logic                  hcbcfe_i;
  logic                  mcbze_i;
  logic                  scbze_i;
  logic                  hcbze_i;
  logic [        0:0]    smt_hart_id_i;
  logic                  debug_from_trigger_i;

  scoreboard_entry_t     instruction_o;
  logic [       31:0]    orig_instr_o;
  logic                  is_control_flow_instr_o;

  decoder #(
      .CVA6Cfg            (Cfg),
      .branchpredict_sbe_t(branchpredict_sbe_t),
      .exception_t        (exception_t),
      .irq_ctrl_t         (irq_ctrl_t),
      .scoreboard_entry_t (scoreboard_entry_t),
      .interrupts_t       (interrupts_t),
      .INTERRUPTS         (INTERRUPTS)
  ) dut (.*);

  // ---- the contract --------------------------------------------------------
  // `dut.illegal_instr` is the decoder's own internal verdict; reaching into it
  // is the whole point (the bug was that this verdict exists and is then
  // dropped), and is why this proof must use `read_slang` -- the classic Yosys
  // frontend would invent a dangling wire here and pass vacuously.
  logic decode_says_illegal;
  assign decode_says_illegal = (dut.illegal_instr || is_illegal_i) && !ex_i.valid;

  // No interrupt may be pending: an interrupt legitimately overrides the
  // instruction's own exception (decoder.sv:2097 sets ex.valid/cause from
  // interrupt_cause), and that override is correct, not a withheld trap. This
  // is a *precondition of the sentence*, not a convenience assumption -- it
  // excludes a different architectural case, it does not excuse the one under
  // test.
  always_comb begin
    assume (irq_i == 2'b00);
    assume (irq_ctrl_i.global_enable == 1'b0);
  end

  always_comb begin
    // I-DELIVER: decode never withholds an illegal-instruction exception.
    a_illegal_raises_ex :
    assert (!decode_says_illegal || instruction_o.ex.valid);

    // ...and it is reported as the right cause. A raised-but-mislabelled trap
    // would send the handler down the wrong path, so the cause is part of the
    // obligation rather than a separate nicety.
    a_illegal_cause :
    assert (!(decode_says_illegal && instruction_o.ex.valid) ||
            instruction_o.ex.cause == riscv::ILLEGAL_INSTR);

    // An instruction carrying an exception must be marked ready to commit --
    // otherwise it can neither trap nor retire, which is the wedge signature
    // (decoder.sv:1953 ties instruction_o.valid to ex.valid).
    a_ex_is_committable :
    assert (!instruction_o.ex.valid || instruction_o.valid);
  end
`endif

endmodule
