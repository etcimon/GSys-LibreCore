// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: CERN-OHL-S-2.0 OR LicenseRef-GSys-Commercial
//
// U6.1 banked CSR regfile for coarse-grain SMT.
//
// NrHarts==1: single csr_regfile (bit-identical path; active_hart ignored).
// NrHarts>1:  one csr_regfile per hart.
//   - Commit/exception/CSR-op gated by commit_instr.hart_id (fine-grain drain)
//   - Async IRQ/timer: per-hart lines (Linux CLINT/PLIC context identity)
//   - Architectural outputs muxed by active_hart_i (fetch/decode privilege view)
//
// mhartid for bank h = hart_id_base_i + h (software-visible thread ids).
// When NrHarts==1, time_irq_i/ipi_i/irq_i widths collapse to the legacy scalars.

module g6lc_smt_csr_bank
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg            = config_pkg::cva6_cfg_empty,
    parameter type                   exception_t        = logic,
    parameter type                   jvt_t              = logic,
    parameter type                   irq_ctrl_t         = logic,
    parameter type                   scoreboard_entry_t = logic,
    parameter type                   rvfi_probes_csr_t  = logic,
    parameter int                    VmidWidth          = 1,
    parameter int unsigned           MHPMCounterNum     = 6,
    parameter int unsigned           N_Triggers         = 4
) (
    input  logic clk_i,
    input  logic rst_ni,
    input  logic [$clog2(CVA6Cfg.NrHarts > 1 ? CVA6Cfg.NrHarts : 2)-1:0] active_hart_i,
    input  logic switch_i,  // gate commit during switch cycle

    // Per-hart CLINT timer / IPI (index = local SMT bank)
    input  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0] time_irq_i,
    input  logic [63:0] rtc_time_i,
    output logic flush_o,
    output logic halt_csr_o,
    input  scoreboard_entry_t commit_instr_i,
    input  logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack_i,
    input  logic [CVA6Cfg.VLEN-1:0] boot_addr_i,
    input  logic [CVA6Cfg.XLEN-1:0] hart_id_base_i,
    input  exception_t ex_i,
    input  fu_op csr_op_i,
    input  logic [11:0] csr_addr_i,
    input  logic [CVA6Cfg.XLEN-1:0] csr_wdata_i,
    output logic [CVA6Cfg.XLEN-1:0] csr_rdata_o,
    input  logic dirty_fp_state_i,
    input  logic csr_write_fflags_i,
    input  logic dirty_v_state_i,
    input  logic [CVA6Cfg.VLEN-1:0] pc_i,
    output exception_t csr_exception_o,
    output logic [CVA6Cfg.VLEN-1:0] epc_o,
    output logic eret_o,
    output logic [CVA6Cfg.VLEN-1:0] trap_vector_base_o,
    output riscv::priv_lvl_t priv_lvl_o,
    output logic mbe_o,
    output logic v_o,
    input  logic [4:0] acc_fflags_ex_i,
    input  logic acc_fflags_ex_valid_i,
    output riscv::xs_t fs_o,
    output riscv::xs_t vfs_o,
    output logic [4:0] fflags_o,
    output logic [2:0] frm_o,
    output logic [6:0] fprec_o,
    output riscv::xs_t vs_o,
    output irq_ctrl_t irq_ctrl_o,
    output logic en_translation_o,
    output logic en_g_translation_o,
    output logic en_ld_st_translation_o,
    output logic en_ld_st_g_translation_o,
    output riscv::priv_lvl_t ld_st_priv_lvl_o,
    output logic ld_st_v_o,
    input  logic csr_hs_ld_st_inst_i,
    output logic sum_o,
    output logic vs_sum_o,
    output logic mxr_o,
    output logic vmxr_o,
    output logic [CVA6Cfg.PPNW-1:0] satp_ppn_o,
    output logic [CVA6Cfg.ASID_WIDTH-1:0] asid_o,
    output logic [CVA6Cfg.PPNW-1:0] vsatp_ppn_o,
    output logic [CVA6Cfg.ASID_WIDTH-1:0] vs_asid_o,
    output logic [CVA6Cfg.PPNW-1:0] hgatp_ppn_o,
    output logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_o,
    output riscv::cbie_t mcbie_o,
    output riscv::cbie_t scbie_o,
    output riscv::cbie_t hcbie_o,
    output logic mcbcfe_o,
    output logic scbcfe_o,
    output logic hcbcfe_o,
    output logic mcbze_o,
    output logic scbze_o,
    output logic hcbze_o,
    output logic pbmte_o,
    // Per-hart external IRQ pair (M/S) and soft-IRQ (width 1 when NrHarts==1)
    input  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0][1:0] irq_i,
    input  logic [(CVA6Cfg.NrHarts < 1 ? 1 : CVA6Cfg.NrHarts)-1:0]     ipi_i,
    input  logic debug_req_i,
    output logic set_debug_pc_o,
    output logic tvm_o,
    output logic tw_o,
    output logic vtw_o,
    output logic tsr_o,
    output logic hu_o,
    output logic debug_mode_o,
    output logic single_step_o,
    output logic icache_en_o,
    output logic dcache_en_o,
    output logic acc_cons_en_o,
    output logic [11:0] perf_addr_o,
    output logic [CVA6Cfg.XLEN-1:0] perf_data_o,
    input  logic [CVA6Cfg.XLEN-1:0] perf_data_i,
    output logic perf_we_o,
    input  logic [31:0] scountovf_i,
    input  logic lcofi_i,
    output riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0] pmpcfg_o,
    output logic [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_o,
    output logic [31:0] mcountinhibit_o,
    output rvfi_probes_csr_t rvfi_csr_o,
    output jvt_t jvt_o,
    output logic debug_from_trigger_o,
    input  logic [CVA6Cfg.VLEN-1:0] vaddr_from_lsu_i,
    input  logic [CVA6Cfg.NrIssuePorts-1:0][31:0] orig_instr_i,
    input  logic [CVA6Cfg.XLEN-1:0] store_result_i,
    output logic break_from_trigger_o
);

  localparam int unsigned NH    = (CVA6Cfg.NrHarts < 1) ? 1 : CVA6Cfg.NrHarts;
  localparam int unsigned HID_W = (NH <= 1) ? 1 : $clog2(NH);

  // ---------- single-hart path ----------
  if (NH <= 1) begin : gen_single
    csr_regfile #(
        .CVA6Cfg           (CVA6Cfg),
        .exception_t       (exception_t),
        .jvt_t             (jvt_t),
        .irq_ctrl_t        (irq_ctrl_t),
        .scoreboard_entry_t(scoreboard_entry_t),
        .rvfi_probes_csr_t (rvfi_probes_csr_t),
        .VmidWidth         (VmidWidth),
        .MHPMCounterNum    (MHPMCounterNum),
        .N_Triggers        (N_Triggers)
    ) i_csr (
        .clk_i,
        .rst_ni,
        .time_irq_i(time_irq_i[0]),
        .rtc_time_i,
        .flush_o,
        .halt_csr_o,
        .commit_instr_i,
        .commit_ack_i,
        .boot_addr_i,
        .hart_id_i(hart_id_base_i),
        .ex_i,
        .csr_op_i,
        .csr_addr_i,
        .csr_wdata_i,
        .csr_rdata_o,
        .dirty_fp_state_i,
        .csr_write_fflags_i,
        .dirty_v_state_i,
        .pc_i,
        .csr_exception_o,
        .epc_o,
        .eret_o,
        .trap_vector_base_o,
        .priv_lvl_o,
        .mbe_o,
        .v_o,
        .acc_fflags_ex_i,
        .acc_fflags_ex_valid_i,
        .fs_o,
        .vfs_o,
        .fflags_o,
        .frm_o,
        .fprec_o,
        .vs_o,
        .irq_ctrl_o,
        .en_translation_o,
        .en_g_translation_o,
        .en_ld_st_translation_o,
        .en_ld_st_g_translation_o,
        .ld_st_priv_lvl_o,
        .ld_st_v_o,
        .csr_hs_ld_st_inst_i,
        .sum_o,
        .vs_sum_o,
        .mxr_o,
        .vmxr_o,
        .satp_ppn_o,
        .asid_o,
        .vsatp_ppn_o,
        .vs_asid_o,
        .hgatp_ppn_o,
        .vmid_o,
        .mcbie_o,
        .scbie_o,
        .hcbie_o,
        .mcbcfe_o,
        .scbcfe_o,
        .hcbcfe_o,
        .mcbze_o,
        .scbze_o,
        .hcbze_o,
        .pbmte_o,
        .irq_i(irq_i[0]),
        .ipi_i(ipi_i[0]),
        .debug_req_i,
        .set_debug_pc_o,
        .tvm_o,
        .tw_o,
        .vtw_o,
        .tsr_o,
        .hu_o,
        .debug_mode_o,
        .single_step_o,
        .icache_en_o,
        .dcache_en_o,
        .acc_cons_en_o,
        .perf_addr_o,
        .perf_data_o,
        .perf_data_i,
        .perf_we_o,
        .scountovf_i,
        .lcofi_i,
        .pmpcfg_o,
        .pmpaddr_o,
        .mcountinhibit_o,
        .rvfi_csr_o,
        .jvt_o,
        .debug_from_trigger_o,
        .vaddr_from_lsu_i,
        .orig_instr_i,
        .store_result_i,
        .break_from_trigger_o
    );
  end else begin : gen_banked
    // Fine-grain SMT: commit-side ops select the *committing instruction's*
    // hart bank (allows drain after switch). Privilege outputs mux by active
    // fetch hart. Async IRQ/timer fan into every bank.
    logic [NH-1:0] commit_sel;
    logic [CVA6Cfg.NrCommitPorts-1:0] commit_ack_g[NH];
    exception_t ex_g[NH];
    fu_op csr_op_g[NH];
    logic dirty_fp_g[NH];
    logic csr_wff_g[NH];
    logic dirty_v_g[NH];
    logic acc_ff_v_g[NH];

    for (genvar h = 0; h < NH; h++) begin : gen_gate
      assign commit_sel[h] = (commit_instr_i.hart_id == HID_W'(h));
      assign commit_ack_g[h] = commit_ack_i & {CVA6Cfg.NrCommitPorts{commit_sel[h]}};
      assign ex_g[h] = commit_sel[h] ? ex_i : '0;
      assign csr_op_g[h] = commit_sel[h] ? csr_op_i : fu_op'(ADD);  // non-CSR idle
      assign dirty_fp_g[h] = dirty_fp_state_i & commit_sel[h];
      assign csr_wff_g[h] = csr_write_fflags_i & commit_sel[h];
      assign dirty_v_g[h] = dirty_v_state_i & commit_sel[h];
      assign acc_ff_v_g[h] = acc_fflags_ex_valid_i & commit_sel[h];
    end

    // Bank outputs
    logic flush_b[NH];
    logic halt_b[NH];
    logic [CVA6Cfg.XLEN-1:0] csr_rdata_b[NH];
    exception_t csr_ex_b[NH];
    logic [CVA6Cfg.VLEN-1:0] epc_b[NH];
    logic eret_b[NH];
    logic [CVA6Cfg.VLEN-1:0] tvec_b[NH];
    riscv::priv_lvl_t priv_b[NH];
    logic mbe_b[NH];
    logic v_b[NH];
    riscv::xs_t fs_b[NH], vfs_b[NH], vs_b[NH];
    logic [4:0] fflags_b[NH];
    logic [2:0] frm_b[NH];
    logic [6:0] fprec_b[NH];
    irq_ctrl_t irq_ctrl_b[NH];
    logic en_tr_b[NH], en_gtr_b[NH], en_ld_tr_b[NH], en_ld_gtr_b[NH];
    riscv::priv_lvl_t ld_st_priv_b[NH];
    logic ld_st_v_b[NH];
    logic sum_b[NH], vs_sum_b[NH], mxr_b[NH], vmxr_b[NH];
    logic [CVA6Cfg.PPNW-1:0] satp_b[NH], vsatp_b[NH], hgatp_b[NH];
    logic [CVA6Cfg.ASID_WIDTH-1:0] asid_b[NH], vs_asid_b[NH];
    logic [CVA6Cfg.VMID_WIDTH-1:0] vmid_b[NH];
    riscv::cbie_t mcbie_b[NH], scbie_b[NH], hcbie_b[NH];
    logic mcbcfe_b[NH], scbcfe_b[NH], hcbcfe_b[NH];
    logic mcbze_b[NH], scbze_b[NH], hcbze_b[NH];
    logic pbmte_b[NH];
    logic set_dbg_b[NH];
    logic tvm_b[NH], tw_b[NH], vtw_b[NH], tsr_b[NH], hu_b[NH];
    logic dbg_mode_b[NH], step_b[NH];
    logic icache_b[NH], dcache_b[NH], acc_cons_b[NH];
    logic [11:0] perf_addr_b[NH];
    logic [CVA6Cfg.XLEN-1:0] perf_data_b[NH];
    logic perf_we_b[NH];
    riscv::pmpcfg_t [avoid_neg(CVA6Cfg.NrPMPEntries-1):0] pmpcfg_b[NH];
    logic [avoid_neg(CVA6Cfg.NrPMPEntries-1):0][CVA6Cfg.PLEN-3:0] pmpaddr_b[NH];
    logic [31:0] mcountinh_b[NH];
    rvfi_probes_csr_t rvfi_b[NH];
    jvt_t jvt_b[NH];
    logic dbg_trig_b[NH], brk_trig_b[NH];

    for (genvar h = 0; h < NH; h++) begin : gen_csr
      csr_regfile #(
          .CVA6Cfg           (CVA6Cfg),
          .exception_t       (exception_t),
          .jvt_t             (jvt_t),
          .irq_ctrl_t        (irq_ctrl_t),
          .scoreboard_entry_t(scoreboard_entry_t),
          .rvfi_probes_csr_t (rvfi_probes_csr_t),
          .VmidWidth         (VmidWidth),
          .MHPMCounterNum    (MHPMCounterNum),
          .N_Triggers        (N_Triggers)
      ) i_csr (
          .clk_i,
          .rst_ni,
          .time_irq_i(time_irq_i[h]),
          .rtc_time_i,
          .flush_o(flush_b[h]),
          .halt_csr_o(halt_b[h]),
          .commit_instr_i(commit_instr_i),
          .commit_ack_i(commit_ack_g[h]),
          .boot_addr_i,
          .hart_id_i(hart_id_base_i + CVA6Cfg.XLEN'(h)),
          .ex_i(ex_g[h]),
          .csr_op_i(csr_op_g[h]),
          .csr_addr_i(csr_addr_i),
          .csr_wdata_i(csr_wdata_i),
          .csr_rdata_o(csr_rdata_b[h]),
          .dirty_fp_state_i(dirty_fp_g[h]),
          .csr_write_fflags_i(csr_wff_g[h]),
          .dirty_v_state_i(dirty_v_g[h]),
          .pc_i(pc_i),
          .csr_exception_o(csr_ex_b[h]),
          .epc_o(epc_b[h]),
          .eret_o(eret_b[h]),
          .trap_vector_base_o(tvec_b[h]),
          .priv_lvl_o(priv_b[h]),
          .mbe_o(mbe_b[h]),
          .v_o(v_b[h]),
          .acc_fflags_ex_i(acc_fflags_ex_i),
          .acc_fflags_ex_valid_i(acc_ff_v_g[h]),
          .fs_o(fs_b[h]),
          .vfs_o(vfs_b[h]),
          .fflags_o(fflags_b[h]),
          .frm_o(frm_b[h]),
          .fprec_o(fprec_b[h]),
          .vs_o(vs_b[h]),
          .irq_ctrl_o(irq_ctrl_b[h]),
          .en_translation_o(en_tr_b[h]),
          .en_g_translation_o(en_gtr_b[h]),
          .en_ld_st_translation_o(en_ld_tr_b[h]),
          .en_ld_st_g_translation_o(en_ld_gtr_b[h]),
          .ld_st_priv_lvl_o(ld_st_priv_b[h]),
          .ld_st_v_o(ld_st_v_b[h]),
          .csr_hs_ld_st_inst_i(csr_hs_ld_st_inst_i),
          .sum_o(sum_b[h]),
          .vs_sum_o(vs_sum_b[h]),
          .mxr_o(mxr_b[h]),
          .vmxr_o(vmxr_b[h]),
          .satp_ppn_o(satp_b[h]),
          .asid_o(asid_b[h]),
          .vsatp_ppn_o(vsatp_b[h]),
          .vs_asid_o(vs_asid_b[h]),
          .hgatp_ppn_o(hgatp_b[h]),
          .vmid_o(vmid_b[h]),
          .mcbie_o(mcbie_b[h]),
          .scbie_o(scbie_b[h]),
          .hcbie_o(hcbie_b[h]),
          .mcbcfe_o(mcbcfe_b[h]),
          .scbcfe_o(scbcfe_b[h]),
          .hcbcfe_o(hcbcfe_b[h]),
          .mcbze_o(mcbze_b[h]),
          .scbze_o(scbze_b[h]),
          .hcbze_o(hcbze_b[h]),
          .pbmte_o(pbmte_b[h]),
          .irq_i(irq_i[h]),
          .ipi_i(ipi_i[h]),
          .debug_req_i,
          .set_debug_pc_o(set_dbg_b[h]),
          .tvm_o(tvm_b[h]),
          .tw_o(tw_b[h]),
          .vtw_o(vtw_b[h]),
          .tsr_o(tsr_b[h]),
          .hu_o(hu_b[h]),
          .debug_mode_o(dbg_mode_b[h]),
          .single_step_o(step_b[h]),
          .icache_en_o(icache_b[h]),
          .dcache_en_o(dcache_b[h]),
          .acc_cons_en_o(acc_cons_b[h]),
          .perf_addr_o(perf_addr_b[h]),
          .perf_data_o(perf_data_b[h]),
          .perf_data_i(perf_data_i),
          .perf_we_o(perf_we_b[h]),
          .scountovf_i,
          .lcofi_i,
          .pmpcfg_o(pmpcfg_b[h]),
          .pmpaddr_o(pmpaddr_b[h]),
          .mcountinhibit_o(mcountinh_b[h]),
          .rvfi_csr_o(rvfi_b[h]),
          .jvt_o(jvt_b[h]),
          .debug_from_trigger_o(dbg_trig_b[h]),
          .vaddr_from_lsu_i,
          .orig_instr_i,
          .store_result_i,
          .break_from_trigger_o(brk_trig_b[h])
      );
    end

    // Mux by active hart
    always_comb begin
      flush_o                  = flush_b[active_hart_i];
      halt_csr_o               = halt_b[active_hart_i];
      csr_rdata_o              = csr_rdata_b[active_hart_i];
      csr_exception_o          = csr_ex_b[active_hart_i];
      epc_o                    = epc_b[active_hart_i];
      eret_o                   = eret_b[active_hart_i];
      trap_vector_base_o       = tvec_b[active_hart_i];
      priv_lvl_o               = priv_b[active_hart_i];
      mbe_o                    = mbe_b[active_hart_i];
      v_o                      = v_b[active_hart_i];
      fs_o                     = fs_b[active_hart_i];
      vfs_o                    = vfs_b[active_hart_i];
      fflags_o                 = fflags_b[active_hart_i];
      frm_o                    = frm_b[active_hart_i];
      fprec_o                  = fprec_b[active_hart_i];
      vs_o                     = vs_b[active_hart_i];
      irq_ctrl_o               = irq_ctrl_b[active_hart_i];
      en_translation_o         = en_tr_b[active_hart_i];
      en_g_translation_o       = en_gtr_b[active_hart_i];
      en_ld_st_translation_o   = en_ld_tr_b[active_hart_i];
      en_ld_st_g_translation_o = en_ld_gtr_b[active_hart_i];
      ld_st_priv_lvl_o         = ld_st_priv_b[active_hart_i];
      ld_st_v_o                = ld_st_v_b[active_hart_i];
      sum_o                    = sum_b[active_hart_i];
      vs_sum_o                 = vs_sum_b[active_hart_i];
      mxr_o                    = mxr_b[active_hart_i];
      vmxr_o                   = vmxr_b[active_hart_i];
      satp_ppn_o               = satp_b[active_hart_i];
      asid_o                   = asid_b[active_hart_i];
      vsatp_ppn_o              = vsatp_b[active_hart_i];
      vs_asid_o                = vs_asid_b[active_hart_i];
      hgatp_ppn_o              = hgatp_b[active_hart_i];
      vmid_o                   = vmid_b[active_hart_i];
      mcbie_o                  = mcbie_b[active_hart_i];
      scbie_o                  = scbie_b[active_hart_i];
      hcbie_o                  = hcbie_b[active_hart_i];
      mcbcfe_o                 = mcbcfe_b[active_hart_i];
      scbcfe_o                 = scbcfe_b[active_hart_i];
      hcbcfe_o                 = hcbcfe_b[active_hart_i];
      mcbze_o                  = mcbze_b[active_hart_i];
      scbze_o                  = scbze_b[active_hart_i];
      hcbze_o                  = hcbze_b[active_hart_i];
      pbmte_o                  = pbmte_b[active_hart_i];
      set_debug_pc_o           = set_dbg_b[active_hart_i];
      tvm_o                    = tvm_b[active_hart_i];
      tw_o                     = tw_b[active_hart_i];
      vtw_o                    = vtw_b[active_hart_i];
      tsr_o                    = tsr_b[active_hart_i];
      hu_o                     = hu_b[active_hart_i];
      debug_mode_o             = dbg_mode_b[active_hart_i];
      single_step_o            = step_b[active_hart_i];
      icache_en_o              = icache_b[active_hart_i];
      dcache_en_o              = dcache_b[active_hart_i];
      acc_cons_en_o            = acc_cons_b[active_hart_i];
      perf_addr_o              = perf_addr_b[active_hart_i];
      perf_data_o              = perf_data_b[active_hart_i];
      perf_we_o                = perf_we_b[active_hart_i];
      pmpcfg_o                 = pmpcfg_b[active_hart_i];
      pmpaddr_o                = pmpaddr_b[active_hart_i];
      mcountinhibit_o          = mcountinh_b[active_hart_i];
      rvfi_csr_o               = rvfi_b[active_hart_i];
      jvt_o                    = jvt_b[active_hart_i];
      debug_from_trigger_o     = dbg_trig_b[active_hart_i];
      break_from_trigger_o     = brk_trig_b[active_hart_i];
    end
  end

endmodule
