// Copyright 2026 Etienne Cimon
// SPDX-License-Identifier: MIT
// CPU51 core-scc gate-level wrapper: mirrors the tb_g6lc_storamic_cpu_origin
// cva6 instantiation exactly (same config build, type parameters, tied
// inputs) with clk/reset as free inputs. Diagnostic only; not for simulation
// or promotion. Derived from the CPU40/41 g6lc_cpu40_top proof wrapper.
`include "axi/typedef.svh"
module g6lc_core_scc_top #(parameter bit OriginEnabled = 1)
    (input logic clk_i, input logic rst_ni);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_user_cfg_t u = cva6_config_pkg::cva6_cfg;
    config_pkg::cva6_cfg_t c;
    c = build_config_pkg::build_config(u);
    if (OriginEnabled) begin
      c.StoramicEn = 1;
      c.StoramicIoEn = 1;
      c.StoramicCheckpointEn = 1;
    end
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();
  typedef logic [Cfg.AxiAddrWidth-1:0] addr_t;
  typedef logic [Cfg.AxiIdWidth-1:0] id_t;
  typedef logic [Cfg.AxiDataWidth-1:0] data_t;
  typedef logic [Cfg.AxiDataWidth/8-1:0] strb_t;
  typedef logic [Cfg.AxiUserWidth-1:0] user_t;
  `AXI_TYPEDEF_ALL(cpu, addr_t, id_t, data_t, strb_t, user_t)
  localparam logic [63:0] Boot = 64'h8000_0000;
  cpu_req_t req;
  cpu_resp_t resp;

  cva6 #(.CVA6Cfg(Cfg), .noc_req_t(cpu_req_t), .noc_resp_t(cpu_resp_t)) cpu (
    .clk_i(clk_i), .rst_ni(rst_ni), .boot_addr_i(Boot), .hart_id_i('0),
    .irq_i('0), .ipi_i('0), .time_irq_i('0), .rtc_time_i('0), .debug_req_i(1'b0),
    .core_wfi_all_o(), .core_wake_o(), .rvfi_probes_o(), .cvxif_req_o(), .cvxif_resp_i('0),
    .ai_aicfg_o(), .ai_ais_o(), .ai_issue_ok_o(), .ai_q_en_o(), .ai_qid_o(),
    .dirty_ai_state_i(1'b0), .ai_setcfg_we_i(1'b0), .ai_setcfg_wdata_i('0),
    .ai_pmu_op_i(1'b0), .ai_pmu_mma_i(1'b0), .ai_pmu_post_i(1'b0),
    .ai_pmu_t0_i(1'b0), .ai_pmu_busy_i(1'b0), .noc_req_o(req), .noc_resp_i(resp),
    .l1_inval_addr_i('0), .l1_inval_valid_i(1'b0), .l1_inval_ready_o(),
    .cmo_valid_o(), .cmo_op_o(), .cmo_addr_o(), .cmo_ready_i(1'b0), .cmo_done_i(1'b0),
    .l2_miss_i(1'b0), .l3_hit_i(1'b0), .l3_miss_i(1'b0), .pf_issue_i(1'b0),
    .pf_train_i(1'b0), .l2_pwhold_i(1'b0), .l3_pwhold_i(1'b0),
    .l2_pf_issue_i(1'b0), .l2_pf_useful_i(1'b0),
    .coh_sf_filtered_i(1'b0), .coh_sf_broadcast_i(1'b0)
  );
endmodule
